# Common utility functions

require 'colorator'
require 'uri'

# Debug puts
def dputs(s)
  if $debug
    puts s
  end
end

def cleanup_uri(uri)
  if uri.nil? then return uri end

  # all public urls should be https if they're 
  m = uri.match(/^[A-Za-z]+\@/)
  unless m.nil?
    uri = 'https://'+uri[m[0].length..-1].sub(':','/')
  end

  p_uri = URI(uri)

  # googlecode uris need to be http and not https otherwise *boom*
  if p_uri.hostname.include? 'googlecode'
    p_uri.scheme = 'http'
  end

  git = false
  if p_uri.scheme == 'git'
    p_uri.scheme = 'http'
    git = true
  end

  if p_uri.hostname.include? '.svn.sourceforge.net'
    project = p_uri.hostname.split('.')[0]
    p_uri.hostname = 'svn.code.sf.net'
    
    path = p_uri.path.split('/svnroot/'+project)
    p_uri.path = File.join('/p',project,'code',path)
  end

  if p_uri.hostname.include? 'sourceforge.net' and git
    p_uri.hostname = 'git.code.sf.net'
  end

  return p_uri.to_s
end

def get_id(uri)
  # combines the domain name and path, hyphenated
  # TODO: maybe intelligently determine svn trunk urls?
  p_uri = URI(uri)
  host = p_uri.host
  path = p_uri.path.sub(/\.git$/,'')
  strip_tld = ['com','org','edu','net']
  return (host.split('.').reject{|v| if v.length < 3 or strip_tld.include?(v) then v end} + path.split(%r{[./]}).reject{|v| if v.length == 0 then true end}).join('-')
end


class IndexException < RuntimeError
  attr :msg, :repo_id
  def initialize(msg, repo_id = 'UNKNOWN')
    @msg = msg
    @repo_id = repo_id
    puts ("ERROR (#{@repo_id}): #{@msg}").red
  end

  def to_hash
    return {'msg'=>@msg, 'repo_id'=>@repo_id}
  end
end

