# Common utility functions

require 'uri'

# Debug puts
def dputs(s)
  if $debug
    puts s
  end
end

def cleanup_uri(uri)
  if uri.nil? then return uri end

  p_uri = URI(uri)

  # googlecode uris need to be http and not https otherwise *boom*
  if p_uri.hostname.include? 'googlecode'
    p_uri.scheme = 'http'
  end

  return p_uri.to_s
end
