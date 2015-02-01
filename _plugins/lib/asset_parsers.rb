
require 'rexml/document'
require 'rexml/xpath'

def parse_launch_file(path, relpath)
  
  puts " ---- Parsing launchfile: #{path}"

  launch_xml = IO.read(path.to_s)
  doc = REXML::Document.new(launch_xml)

  launch_data = {
    'relpath' => relpath,
    'args' => REXML::XPath.each(doc, '//arg').map {|e| e.attributes},
    'includes' => REXML::XPath.each(doc, '//include').map {|e| e.attributes},
    'nodes' => REXML::XPath.each(doc, '//node').map {|e| e.attributes}
  }

  return launch_data
end
