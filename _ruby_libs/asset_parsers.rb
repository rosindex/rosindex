
require 'rexml/document'
require 'rexml/xpath'

def parse_launch_file(path, relpath)
  
  dputs " ---- Parsing launchfile: #{path}"

  launch_xml = IO.read(path.to_s)
  doc = REXML::Document.new(launch_xml)

  launch_data = {
    'relpath' => relpath,
    'comment' => if doc.comments.length >0 then doc.comments[0].to_s else '' end,
    'args' => REXML::XPath.each(doc, '//arg').map {|e| e.attributes},
    'includes' => REXML::XPath.each(doc, '//include').map {|e| e.attributes},
    'nodes' => REXML::XPath.each(doc, '//node').map {|e| e.attributes}
  }

  return launch_data
end
