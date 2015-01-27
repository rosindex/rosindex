
def get_id(uri)
  # combines the domain name and path, hyphenated
  p_uri = URI(uri)
  return (p_uri.host.split('.').reject{|v| if v.length < 3 or v == 'com' or v == 'org' or v == 'edu' then v end} + p_uri.path.split(%r{[./]}).reject{|v| if v.length == 0 then true end}[0,2]).join('-')
end

class PackageSnapshot < Liquid::Drop
  # This represents a snapshot of a ROS package found in a repo snapshot
  attr_accessor :name, :repo, :snapshot, :version, :data
  def initialize(name, repo, snapshot, data)
    @name = name

    # TODO: get rid of these back-pointers
    @repo = repo
    @snapshot = snapshot
    @version = snapshot.version

    # additionally-collected data
    @data = data
  end
end

class RepoSnapshot < Liquid::Drop
  # This represents a snapshot of a version control repository
  attr_accessor :released, :distro, :version, :data, :packages
  def initialize(version, distro, released)
    # the version control system version string
    # this is either a branch or tag of the remote repo
    @version = version

    # whether this snapshot is released
    @released = released

    # the distro that this snapshot works with
    @distro = distro

    # metadata about this snapshot
    @data = {}

    # package name -> PackageSnapshot
    # these are all the packages in this repo snapshot
    @packages = {}
  end
end

class Repo < Liquid::Drop
  # This represents a remote repository
  attr_accessor :name, :id, :uri, :purpose, :snapshots, :tags, :type, :status, :local_path, :local_name
  def initialize(name, type, uri, purpose, checkout_path)
    # unique identifier
    @id = get_id(uri)

    # non-unique identifier for this repo
    @name = name

    # the uri for cloning this repo
    @uri = cleanup_uri(uri)

    # the version control system type
    @type = type

    # a brief description of this remote
    @purpose = purpose

    # maintainer status
    @status = nil

    # the local repo name to checkout to (this is important for older rosbuild packages)
    @local_name = name

    # the local path to this repo
    @local_path = File.join(checkout_path, @name, @id, @local_name)

    # hash distro -> RepoSnapshot
    # each entry in this hash represents the preferred version for a given distro in this repo
    @snapshots = Hash[$all_distros.collect { |d| [d, RepoSnapshot.new(nil, d, false)] }]

    # tags from all versions
    @tags = []
  end
end

class RepoInstances < Liquid::Drop
  # This represents a group of repositories with the same name
  attr_accessor :name, :default, :instances
  def initialize(name)
    # identifier for this repo
    @name = name

    # hash instance_id -> Repo
    # these are all of the known instances of this repo
    @instances = {}

    # reference to the preferred Repo instance
    @default = nil
  end
end

class PackageInstances < Liquid::Drop
  # This represents a group of package snapshots with the same name
  attr_accessor :name, :tags, :instances, :snapshots, :repos
  def initialize(name)
    # name of the package
    @name = name

    # tags from all package instances
    @tags = []

    # hash distro -> RepoSnapshot
    # each entry in this hash is the preferred snapshot for this package
    @repos = Hash[$all_distros.collect { |d| [d, nil] }]
    @snapshots = Hash[$all_distros.collect { |d| [d, nil] }]

    # hash instance_id -> Repo
    # each repo in this hash contains the package in question, even if it's not a preferred snapshot
    @instances = {}
  end
end

class RosIndexDB
  attr_accessor :all_repos, :repo_names, :package_names
  def initialize
    # the global index of repos
    @all_repos = Hash.new
    # the list of repo instances by name
    @repo_names = Hash.new
    # the list of package instances by name
    @package_names = Hash.new

    self.add_procs
  end

  def add_procs
    @repo_names.default_proc = proc do |h, k|
      h[k]=RepoInstances.new(k)
    end

    @package_names.default_proc = proc do |h, k|
      h[k]=PackageInstances.new(k)
    end
  end

  def marshal_dump
    [Hash[@all_repos], Hash[@repo_names], Hash[@package_names]]
  end

  def marshal_load array
    @all_repos, @repo_names, @package_names = array
    self.add_procs
  end
end
