# Tools for rendering of markdown and rst documents

require 'nokogiri'
require 'pandoc-ruby'

# Converts RST to Markdown
def rst_to_md(rst)
  return PandocRuby.convert(rst, :from => :rst, :to => :markdown)
end

# Modifies markdown image links so that they link to github user content
def fix_image_links(text, raw_uri, additional_path = '')
  readme_doc = Nokogiri::HTML(text)
  readme_doc.xpath("//img[@src]").each() do |el|
    #puts 'img: '+el['src'].to_s
    unless el['src'].start_with?('http')
      el['src'] = ('%s/%s/' % [raw_uri, additional_path])+el['src']
    end
  end

  return readme_doc.to_s, readme_doc
end

# Renders markdown to html (and apply some required tweaks)
def render_md(site, readme)
  begin
    mkconverter = site.getConverterImpl(Jekyll::Converters::Markdown)
    readme.gsub! "```","\n```"
    readme.gsub! '```shell','```bash'
    return mkconverter.convert(readme)
  rescue
    return 'Could not convert readme.'
  end
end


def get_md_rst_txt(site, path, glob, raw_uri)

  file_md = nil

  file_files = Dir.glob(File.join(path,glob), File::FNM_CASEFOLD)
  file_files.each do |file_path|
    case File.extname(file_path)
    when '.md'
      file_md = IO.read(file_path)
    when '.rst'
      file_rst = IO.read(file_path)
      file_md = rst_to_md(file_rst)
    when ''
      if not File.directory?(file_path)
        file_txt = IO.read(file_path)
        file_md = "```\n" + file_txt + "\n```"
      else
        next
      end
    else
      file_txt = IO.read(file_path)
      file_md = "```\n" + file_txt + "\n```"
    end
    break
  end

  if file_md
    # read in the file and fix links
    file_html = render_md(site, file_md)
    file_html = '<div class="rendered-markdown">'+file_html+"</div>"
    file_rendered, _ = fix_image_links(file_html, raw_uri)
  else
    file_rendered = nil
  end

  return file_rendered, file_md
end
