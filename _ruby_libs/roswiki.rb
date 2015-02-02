
TITLE_INDEX_URI="http://wiki.ros.org/?action=titleindex"

require 'open-uri'

def get_wiki_title_index(title_index_file)
  open(title_index_file, 'w') do |file|
    file << open(TITLE_INDEX_URI).read
  end
end

def parse_wiki_title_index(title_index_file)

  data = {}

  title_index = IO.read(title_index_file)
  title_index.each_line do |l| 
    tokens = l.rstrip().split('/')
    pkg_name = tokens[0]
    if data.key? pkg_name
      pkg_data = data[pkg_name]
    else
      pkg_data = data[pkg_name] = {
        'exists' => true,
        'tutorials' => []
      }
    end

    if tokens.length > 2
      if tokens[1] == 'Tutorials'
        pkg_data['tutorials'] << [tokens[2..-1].join('/'),l.rstrip()]
      end
    end

    data[pkg_name] = pkg_data
  end
  
  return data
end
