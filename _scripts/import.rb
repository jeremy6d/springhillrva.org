#!/usr/bin/env ruby
# frozen_string_literal: true

# Import WordPress WXR export into Jekyll posts, pages, and assets.
# Usage: ruby _scripts/import.rb [path/to/export.xml]

require "rexml/document"
require "date"
require "fileutils"
require "open-uri"
require "uri"
require "yaml"

PROJECT_ROOT = File.expand_path("..", __dir__)
XML_PATH = ARGV[0] || File.join(PROJECT_ROOT, "_data", "springhillrvaorg.WordPress.2026-02-16.xml")
POSTS_DIR = File.join(PROJECT_ROOT, "_posts")
IMAGES_DIR = File.join(PROJECT_ROOT, "assets", "images")
PAGES_DIR = PROJECT_ROOT

PAGE_SLUGS = %w[
  about-springhill-neighborhood
  contact-us
  mutualaid
].freeze

SKIP_PAGE_SLUGS = %w[shop cart checkout my-account refund_returns].freeze

def element_value(element)
  return "" unless element
  cdata = element.cdatas.map(&:value).join
  return cdata unless cdata.empty?
  element.text.to_s.strip
end

def wp_element(item, local_name)
  item.elements.to_a.find do |e|
    n = e.name.to_s
    n == local_name || n == "wp:#{local_name}" || n.end_with?(":#{local_name}")
  end
end

def field(item, name)
  if name == "content:encoded"
    nodes = item.elements.to_a.select { |e| e.name.to_s == "encoded" }
    node = nodes.max_by { |n| element_value(n).length }
    return element_value(node) if node
    return ""
  end

  local = name.sub(/\Awp:/, "")
  node = wp_element(item, local)
  return "" unless node
  element_value(node)
end

def parse_wp_date(date_str)
  return nil if date_str.nil? || date_str.empty? || date_str.include?("0000-00-00")
  DateTime.parse(date_str)
rescue ArgumentError
  nil
end

def permalink_from_link(link)
  return nil if link.nil? || link.strip.empty?
  uri = URI.parse(link.strip)
  path = uri.path
  path = "/" if path.nil? || path.empty?
  path += "/" unless path.end_with?("/")
  path
rescue URI::InvalidURIError
  nil
end

def safe_filename(name)
  base = File.basename(name.to_s)
  base = "image" if base.empty?
  base.gsub(/[^\w.\-]+/, "-").gsub(/-+/, "-")
end

WAYBACK_TIMESTAMPS = %w[
  20250216120000
  20240415120000
  20230527120000
  20200601120000
  20150301000000
].freeze

def download_file(url, dest_path)
  return true if File.exist?(dest_path) && File.size(dest_path) > 0

  FileUtils.mkdir_p(File.dirname(dest_path))
  sources = [url]
  WAYBACK_TIMESTAMPS.each do |ts|
    sources << "https://web.archive.org/web/#{ts}im_/#{url}"
  end
  if url.include?("6thdensity.net") || url.include?("springhillrva.org/files")
    WAYBACK_TIMESTAMPS.each do |ts|
      sources << "https://web.archive.org/web/#{ts}im_/http://#{url.sub(%r{\Ahttps?://}, '')}"
    end
  end

  sources.each do |src|
    begin
      URI.open(src, "rb", open_timeout: 20, read_timeout: 60, "User-Agent" => "springhillrva-import/1.0") do |io|
        data = io.read
        next if data.nil? || data.bytesize < 200
        next if data[0, 15].to_s.downcase.include?("<!doctype") || data[0, 5] == "<html"

        File.binwrite(dest_path, data)
      end
      return true if File.exist?(dest_path) && File.size(dest_path) > 200
    rescue StandardError
      FileUtils.rm_f(dest_path)
    end
  end
  false
end

def yaml_value(v)
  case v
  when Array
    "[#{v.map { |x| yaml_value(x) }.join(', ')}]"
  when String
    v.include?("\n") || v.match?(/[:#@`]/) ? v.inspect : "\"#{v.gsub('"', '\\"')}\""
  else
    v.inspect
  end
end

class Importer
  attr_reader :attachments_by_id, :image_by_wp_id, :url_to_local, :failed_urls

  def initialize(xml_path)
    @xml_path = xml_path
    @attachments_by_id = {}
    @image_by_wp_id = {}
    @url_to_local = {}
    @failed_urls = []
    @doc = REXML::Document.new(File.read(xml_path))
  end

  def run
    collect_attachments
    download_attachments
    import_content
    report_failures
  end

  def collect_attachments
    @doc.elements.each("rss/channel/item") do |item|
      next unless field(item, "wp:post_type") == "attachment"
      post_id = field(item, "wp:post_id")
      url = field(item, "wp:attachment_url")
      next if post_id.empty? || url.empty?

      filename = safe_filename(URI.parse(url).path)
      local_rel = "/assets/images/#{filename}"
      local_abs = File.join(IMAGES_DIR, filename)

      @attachments_by_id[post_id] = {
        url: url,
        filename: filename,
        local_rel: local_rel,
        local_abs: local_abs
      }
      @image_by_wp_id[post_id] = local_rel
      @url_to_local[url] = local_rel
      @url_to_local[url.sub("https://", "http://")] = local_rel if url.start_with?("https://")
    end
    puts "Found #{@attachments_by_id.size} attachments"
  end

  def download_attachments
    @attachments_by_id.each_value do |att|
      ok = download_file(att[:url], att[:local_abs])
      if ok
        puts "  OK #{att[:filename]}"
      else
        @failed_urls << att[:url]
        puts "  FAIL #{att[:url]}"
      end
    end
  end

  def import_content
    FileUtils.mkdir_p(POSTS_DIR)
    posts = 0
    pages = 0

    @doc.elements.each("rss/channel/item") do |item|
      post_type = field(item, "wp:post_type")
      status = field(item, "wp:status")
      next unless status == "publish"

      title_el = item.elements.to_a.find { |e| e.name == "title" }
      title = element_value(title_el).strip
      post_name = field(item, "wp:post_name").strip
      link_el = item.elements.to_a.find { |e| e.name == "link" }
      link = element_value(link_el)

      case post_type
      when "post"
        next if title.empty?
        write_post(item, title, post_name, link)
        posts += 1
      when "page"
        next unless PAGE_SLUGS.include?(post_name)
        next if SKIP_PAGE_SLUGS.include?(post_name)
        write_page(item, title, post_name, link)
        pages += 1
      end
    end

    puts "\nImported #{posts} posts, #{pages} pages"
  end

  def write_post(item, title, post_name, link)
    date = parse_wp_date(field(item, "wp:post_date")) || DateTime.now
    content = field(item, "content:encoded")
    permalink = permalink_from_link(link) || "/#{date.strftime('%Y/%m/%d')}/#{post_name}/"

    categories = []
    item.elements.each("category[@domain='category']") do |cat|
      nicename = cat.attributes["nicename"]
      categories << nicename unless nicename.to_s.empty?
    end

    body = clean_content(content, item)
    safe_slug = post_name.gsub(%r{[^\w-]+}, "-").gsub(/-+/, "-").sub(/\A-|-\z/, "")
    safe_slug = "post" if safe_slug.empty?
    filename = "#{date.strftime('%Y-%m-%d')}-#{safe_slug}.md"

    fm = {
      "layout" => "post",
      "title" => title,
      "date" => date.strftime("%Y-%m-%d %H:%M:%S %z"),
      "permalink" => permalink,
      "wordpress_id" => field(item, "wp:post_id")
    }
    fm["categories"] = categories unless categories.empty?

    write_markdown(File.join(POSTS_DIR, filename), fm, body)
    puts "Post: #{filename}"
  end

  def write_page(item, title, post_name, link)
    content = field(item, "content:encoded")
    permalink = permalink_from_link(link) || "/#{post_name}/"
    body = clean_content(content, item)

    fm = {
      "layout" => "page",
      "title" => title,
      "permalink" => permalink,
      "wordpress_id" => field(item, "wp:post_id")
    }

    if post_name == "contact-us"
      body = "{% include contact-form.html %}\n"
    end

    write_markdown(File.join(PAGES_DIR, "#{post_name}.md"), fm, body)
    puts "Page: #{post_name}.md"
  end

  def write_markdown(path, front_matter, body)
    lines = ["---"]
    front_matter.each { |k, v| lines << "#{k}: #{yaml_value(v)}" }
    lines.concat(["---", "", body.strip, ""])
    File.write(path, lines.join("\n"))
  end

  def clean_content(html, _item)
    text = html.dup
    text = expand_gallery_shortcodes(text)
    text = convert_captions(text)
    text = strip_shortcodes(text)
    text = strip_wp_blocks(text)
    text = rewrite_image_urls(text)
    text = rewrite_internal_links(text)
    text.strip
  end

  def expand_gallery_shortcodes(text)
    text.gsub(/\[gallery[^\]]*\]/i) do |match|
      exclude = match[/exclude="([^"]+)"/i, 1]&.split(",")&.map(&:strip) || []
      ids = @attachments_by_id.keys.reject { |id| exclude.include?(id) }
      imgs = ids.filter_map do |id|
        att = @attachments_by_id[id]
        next unless att && File.exist?(att[:local_abs])
        %(<figure class="gallery-item"><img src="#{att[:local_rel]}" alt="" loading="lazy"></figure>)
      end
      imgs.empty? ? "" : "<div class=\"gallery\">#{imgs.join}\n</div>"
    end
  end

  def convert_captions(text)
    text.gsub(
      /\[caption[^\]]*\](.*?)\[\/caption\]/im
    ) do
      inner = Regexp.last_match(1)
      cap = Regexp.last_match(0)[/caption="([^"]*)"/i, 1] ||
            Regexp.last_match(0)[/caption='([^']*)'/i, 1] || ""
      inner = rewrite_image_urls(inner)
      "<figure>#{inner}<figcaption>#{cap}</figcaption></figure>"
    end
  end

  def strip_shortcodes(text)
    text
      .gsub(/\[formidable[^\]]*\]/i, "")
      .gsub(/\[contact-form-7[^\]]*\]/i, "")
      .gsub(/<div>\[formidable[^\]]*\]<\/div>/i, "")
      .gsub(/\[[^\]]+\]/, "") # remaining bracket shortcodes
  end

  def strip_wp_blocks(text)
    text.gsub(/<!--\s*\/?wp:[^>]*-->\s*/m, "")
  end

  def rewrite_image_urls(text)
    result = text.dup

    result.gsub!(/src=(["'])([^"']+)\1/i) do
      quote = Regexp.last_match(1)
      url = Regexp.last_match(2)
      local = resolve_image_url(url)
      local ? "src=#{quote}#{local}#{quote}" : "src=#{quote}#{url}#{quote}"
    end

    result.gsub!(/href=(["'])([^"']+\.(?:jpe?g|png|gif|webp|pdf))[^"']*\1/i) do
      quote = Regexp.last_match(1)
      url = Regexp.last_match(2)
      local = resolve_image_url(url)
      local ? "href=#{quote}#{local}#{quote}" : "href=#{quote}#{url}#{quote}"
    end

    result.gsub(/class="[^"]*wp-image-(\d+)[^"]*"/i) do
      id = Regexp.last_match(1)
      @image_by_wp_id[id] ? "" : Regexp.last_match(0)
    end
  end

  def resolve_image_url(url)
    return @url_to_local[url] if @url_to_local[url]

    if url =~ /wp-image-(\d+)/i
      id = Regexp.last_match(1)
      return @image_by_wp_id[id] if @image_by_wp_id[id]
    end

    if (m = url.match(/wp-content\/uploads\/[^"']+/i))
      candidate = "https://www.springhillrva.org/#{m[0]}"
      return @url_to_local[candidate] if @url_to_local[candidate]
    end

    if url.include?("6thdensity.net") || url.include?("springhillrva.org/files")
      filename = safe_filename(URI.parse(url).path)
      dest = File.join(IMAGES_DIR, filename)
      unless File.exist?(dest) && File.size(dest) > 0
        download_file(url, dest) || @failed_urls << url
      end
      if File.exist?(dest) && File.size(dest) > 0
        local = "/assets/images/#{filename}"
        @url_to_local[url] = local
        return local
      end
    end

    nil
  end

  def rewrite_internal_links(text)
    text
      .gsub(%r{https?://(?:www\.)?springhillrva\.org}, "")
      .gsub(%r{http://springhillrva\.org}, "")
      .gsub("index.php/", "")
  end

  def report_failures
    return if @failed_urls.empty?
    puts "\n--- Failed downloads (#{@failed_urls.uniq.size}) ---"
    @failed_urls.uniq.each { |u| puts "  #{u}" }
  end
end

if __FILE__ == $PROGRAM_NAME
  abort "Usage: ruby _scripts/import.rb [path/to/export.xml]" unless File.exist?(XML_PATH)
  Importer.new(XML_PATH).run
end
