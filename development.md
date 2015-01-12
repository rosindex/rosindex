layout: page
---

Reads `rosdistro` files to get lists of released and unreleased ROS
repositories. For all repositories with source links, it adds them
to a known repositories index. 

Files are read from two places in `rosdistro`:

 * `_rosdistro/<<DISTRO>>/distribution.yaml`
 * `_rosdistro/doc/<<DISTRO>>/*.rosinstall`

ROS packages are uniquely located in rosdistro by a distribution (groovy,
hydro, indigo) and a repository identifier. In a given distribution, package
names are unique.

ROSIndex organizes ROS source code in two ways:

 * By repository
 * By package

### Repository Organization

The repository organization is simple: each repository identifier corresponds
to a set of repository `instances`. Repository instances are different versions
of a repository with the same name but different URIs. This enables ROSIndex
to index forks of known repositories. Within each instance, branches and tags
correspond to different ROS distributions. So versions of repositories can be
organized hierarchically like so:

 1. repository identifier
 2. repository instance
 3. ROS distribution (branch/tag)

This gives rise to urls like:

```
rosindex.github.io/r/<<REPOSITORY>>/<<INSTANCE>>/#<<DISTRO>>
```

So for the ``geometry`` repository, the default instance would be resolved by:

```
rosindex.github.io/r/geometry
```

In this case, this would be equivalent to:

```
rosindex.github.io/r/geometry/rosdistro
```

This link would resolve to the repository corresponding to the URI given in the
*latest* rosdistro index. Then the user could switch between distros of *that
repository* with the distro selector buttons.

> Note that the repository for a repository identifier can change between
> distributions. In this case, it is expected that older versions of the sources
> are tagged in the *latest* version of the repository.

Specific instances of packages can be resolved by the following:

 1. repository identifier
 2. repository instance
 3. package name
 4. ROS distribuition (branch/tag)

### Package Organization

Normally, however, users are interested in looking up ROS code by package name.
In this case, it's more subtle. Between ROS distributions, a package can migrate
from one repository to another. As such, a hierarchical organization like that
used for repositories doesn't fit as well. It could have the effect of obscuring
versions of code for a newer or older distribution because it changed
repositories.

Most importantly, people want to see the documentation for *offifical* packeges.
As such, it makes sense that when browsing packages, the default instances for a
distribution are organized like so:

 1. package name
 2. ROS distribution (repo/instance/branch/tag)

When viewing the tab for a given ROS distribution, the user can see additional
metadata about the package, as well as in which repository that package is
located.

## Building ROSIndex

System Requirements:

* ruby 1.9
* subversion 1.8
  * with SWIG ruby bindings and serf (`./configure --with-serf`)
* git
* mercurial

Ruby Requirements:

