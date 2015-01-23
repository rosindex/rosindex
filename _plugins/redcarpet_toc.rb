
class Toc < Liquid::Tag
  def initialize(tag_name, level, tokens)
     super
     @level = level
  end

  def render(context)
    "<h#{@level}>Contents</h#{@level}><div class=\"\" id=\"toc\"></div>"
  end
end

Liquid::Template.register_tag('toc', Toc)
