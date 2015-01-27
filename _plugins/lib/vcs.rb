# Version control systems

require 'colorize'
require 'uri'
require 'typhoeus'

require 'git'
require 'rugged'
require 'mercurial-ruby'

# rosindex requires
require_relative 'common'

class VCS
  # This represents a working copy of a remote repository
  # superlight abstract vcs wrapper
  #
  # features:
  #   - update from remote
  #   - list branches
  #   - list tags
  #   - checkout specific branch / tag
  #   - get latest commit date

  attr_accessor :local_path, :uri, :type
  def initialize(local_path, uri, type)
    @local_path = local_path
    @uri = uri
    @type = type
  end

  def uri_ok?()
    # make sure it is defined
    if @uri.nil? then return false end

    # make sure the uri actually exists
    resp = Typhoeus.get(@uri, followlocation: true, nosignal: true, connecttimeout: 3.0)
    if resp.code == 404 or resp.code == 403
      puts ("ERROR: Code "+resp.code.to_s+" bad URI: " + @uri).red
      return false
    elsif resp.timed_out?
      puts ("ERROR: Timed out URI: " + @uri).red
      return false
    elsif resp.success?
      return true
    end

    puts ("ERROR: Bad URI: " + @uri).red
    return false
  end

  def hash
    return [local_path].hash
  end

  def eql?(other)
    return other.local_path == @local_path
  end

end

class GIT < VCS
  def initialize(local_path, uri)
    super(local_path, uri, 'git')

    @r = nil
    @origin = nil

    if File.exist?(@local_path)
      @r = Rugged::Repository.new(@local_path)
      dputs " - opened git repository at: " << @local_path << " from uri: " << @uri
    else
      @r = Rugged::Repository.init_at(@local_path)
      dputs " - initialized new git repository at: " << @local_path << " from uri: " << @uri
    end

    @origin = @r.remotes['origin']

    if @origin.nil? and self.uri_ok?
      # add remote
      dputs " - adding remote for " << @uri << " to " << @local_path
      @origin = @r.remotes.create('origin', @uri)
    end
  end

  def valid?()
    return (not @origin.nil?)
  end

  def fetch()
    # fetch the remote
    unless $fetched_uris.key?(@uri)
      if true or (File.mtime(File.join(@local_path,'.git')) < (Time.now() - (60*60*24)))
        begin
          dputs " - fetching remote from: " + @uri
          @r.fetch(@origin)
        rescue
          puts ("ERROR: could not fetch git repository from uri: " + @uri).red
        end
      else
        dputs " - not fetching remote "
      end
      # this is no longer useful now that repos are all independent on disk
      #$fetched_uris[@uri] = true
    end
  end

  def checkout(version)

    if version.nil? then return end

    begin
      dputs " --- checking out " << version.name.to_s << " from remote: " << version.remote_name.to_s << " uri: " << @uri
      @r.checkout(version)
    rescue
      dputs " --- resetting hard to " << version.name.to_s
      @r.reset(version.name, :hard)
    end
  end

  def get_last_commit_time()
    return @r.last_commit.time.strftime('%F')
  end

  def get_version(distro, explicit_version = nil)

    # remote head
    if explicit_version == 'REMOTE_HEAD'
      @r.branches.each() do |branch|
        branch.remote.ls.each do |remote_ref|
          if remote_ref[:local] == false and remote_ref[:name] == 'HEAD'
            branch_name = branch.name.split('/')[-1]
            return remote_ref[:oid], branch_name
          end
        end
      end

      return nil, nil
    end

    # get the version if it's a branch
    @r.branches.each() do |branch|
      # ignore this special branch
      if branch.name == 'git-svn' then next end

      # get the branch shortname
      branch_name = branch.name.split('/')[-1]

      # detached branches are those checked out by the system but not given names
      if branch.name.include? 'detached' then next end
      if branch.remote_name != 'origin' then next end

      # NOTE: no longer need to check remote names #if branch.remote_name != repo.id then next end

      #dputs " -- examining branch " << branch.name << " trunc: " << branch_name << " from remote: " << branch.remote_name
      #puts " - should have " << distro << " version " << explicit_version.to_s

      # save the branch as the version if it matches either the explicit
      # version or the distro name
      if explicit_version
        if branch_name == explicit_version
          return branch, branch_name
        end
      elsif branch_name.include? distro
        return branch, branch_name
      end
    end

    # get the version if it's a tag
    @r.tags.each do |tag|
      tag_name = tag.to_s

      # save the tag if it matches either the explicit version or the distro name
      if explicit_version
        if tag_name == explicit_version
          return tag, tag_name
        end
      elsif tag_name.include? distro
        return tag, tag_name
      end
    end

    return nil, nil
  end
end

class HG < VCS
  def initialize(local_path, uri)
    super(local_path, uri, 'hg')

    @r = nil
    @origin = nil

    if self.uri_ok?
      if File.exist?(@local_path) and File.exist?(File.join(@local_path,'.hg'))
        @r = Mercurial::Repository.open(@local_path)
        dputs " - opened hg repository at: " << @local_path << " from uri: " << @uri
      else
        @r = Mercurial::Repository.clone(@uri, @local_path, {})
        dputs " - initialized new hg repository at: " << @local_path << " from uri: " << @uri
      end
    else
      puts ("ERROR: could not reach hg repository at uri: " + @uri).red
    end
  end

  def valid?()
    return (not @r.nil?)
  end

  def fetch()
    # fetch the remote
    if self.valid?
      @r.pull()
    end
  end

  def checkout(version)
    if self.valid?
      dputs " --- checking out " << version.to_s << " uri: " << @uri
      @r.shell.hg(['update ?', version])
    else
    end
  end

  def get_last_commit_time()
    if self.valid?
      return @r.commits.tip.date.strftime('%F')
    else
      return nil
    end
  end

  def get_version(distro, explicit_version = nil)
    # get remote head
    if explicit_version == 'REMOTE_HEAD'
      return 'default', 'default'
    end

    # get the version if it's a branch
    @r.branches.each() do |branch|
      # get the branch shortname
      branch_name = branch.name

      # save the branch as the version if it matches either the explicit
      # version or the distro name
      if explicit_version
        if branch_name == explicit_version
          return branch.name, branch_name
        end
      elsif branch_name.include? distro
        return branch.name, branch_name
      end
    end

    # get the version if it's a tag
    @r.tags.all.each do |tag|
      tag_name = tag.name

      # save the tag if it matches either the explicit version or the distro name
      if explicit_version
        if tag_name == explicit_version
          return tag.name, tag_name
        end
      elsif tag_name.include? distro
        return tag.name, tag_name
      end
    end

    return nil, nil
  end
end

class GITSVN < GIT
  # we hates the subversionses
  # so use git instead!
  # this uses git-svn to clone an svn repo
  def initialize(local_path, uri)
    @local_path = local_path
    @uri = uri
    if self.uri_ok?
      if File.exist?(File.join(local_path,'.svn'))
        system("mv #{local_path} #{local_path}__svn")
      end
      unless File.exist?(File.join(local_path,'.git'))
        # TODO
        system("git svn clone -rHEAD #{uri} #{local_path}")
        dputs " - initialized new git-svn repository at: " << local_path << " from uri: " << uri
      end
    else
      puts ("ERROR: could not reach svn repository at uri: " + uri).red
      return
    end

    super(local_path, uri)
  end

  def get_version(distro, explicit_version = nil)
    if explicit_version == 'REMOTE_HEAD'
      return @r.branches['master'], 'master' # super(distro, explicit_version = 'master')
    else
      return nil, nil
    end
  end

  def fetch
    system('cd "'+@local_path+'" git svn rebase')
  end
end

def get_vcs(repo)

  vcs = nil

  case repo.type
  when 'git'
    dputs "Getting git repo: " + repo.uri.to_s
    vcs = GIT.new(repo.local_path, repo.uri)
  when 'hg'
    dputs "Getting hg repo: " + repo.uri.to_s
    vcs = HG.new(repo.local_path, repo.uri)
  when 'svn'
    dputs "Getting svn repo: " + repo.uri.to_s
    vcs = GITSVN.new(repo.local_path, repo.uri)
  else
    dputs ("Unsupported VCS type: "+repo.type.to_s).red
  end

  if vcs.valid?
    return vcs
  else
    return nil
  end
end

