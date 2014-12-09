ROS Index
=========

A simple static index for known ROS packages on GitHub. It builds in jekyll
with a plugin to pull down information from github, and uses client-side
javascript for quick searching and to fetch additional information from GitHub
like open tickets and active forks.

## Contributing

### Adding a Repository to the Index

Most repositories are listed in the standard
[rosdistro](http://github.com/ros/rosdistro) files. These files contain lists
of repositories containing *both* released and unreleased packages. Even if your
code is experimental, it's important to get it indexed in the main ROS distro
indexes.

### Adding a Fork of a Repository to the Index

Unfortunately, the *rosdistro* standard, as defined in
[REP-141](http://ros.org/reps/rep-0141.html), does not accomodate the indexing
of *forks*. Until the standard is extended to do so, rosindex will support the
indexing of this additional information.

Forks are described in the YAML-formatted markdown files in the `_repos`
directory which correspond to the repository names in *rosdistro*. Each
repository fork should be given an identifying name for easy reference on the
rosindex website.

The only required key is the `url`, but you can also add a `purpose` describing
why the package was forked, as well as `distros` to describe which ROS distros
map to which branches in the repository.

```yaml
forks:
  RCPRG-ros-pkg:
    url: "https://github.com/RCPRG-ros-pkg/conman.git"
    purpose: "Experimental features"
    distros:
      indigo: master
      hydro: master
```

### Adding Package Metadata

Catkin `package.xml` files can be augmented with `<rosindex>` tags in the
`<export>` section, which is meant for 3rd-party use. Adding an empty rosindex
section to a `package.xml` fifle would look like the following:

```xml
<package>
  <!-- required metadata -->
  <!-- ... -->

  <export>
    <rosindex>
      <!-- rosindex-related tags -->
    </rosindex>
  </export>
</package>
```

The metadata described in the following sub-sections must all be added under
a single `<rosindex></rosindex>` tag.

#### REAMDE

***UNIMPLEMENTED***

By default, rosindex will assume that the readme file for a package is titled
`REDME.md` and is placed in the package root. If not, a `<readme></readme>` tag
can be used to specify an alternative.

For example, an alternative readme, stored in a `doc` subdirectory, could be
specified like the following:

```xml
<readme>doc/README.md</readme>
```

#### Tags

Tags are useful for categorizing related ROS packages in rosindex. They are
single words or multiple hyphenated words.

For example, adding the tags `biped`, `planning`, and `real-time` in the
rosindex section would look like the following:

```xml
<tags>
  <tag>biped</tag>
  <tag>planning</tag>
  <tag>real-time</tag>
</tags>
```

#### Tutorials

***UNIMPLEMENTED***

A package can also give a list of a series of tutorials.

```xml
<tutorials>
  <tutorial>doc/tut1.md</tutorial>
  <tutorial>doc/tut2.md</tutorial>
  <tutorial>doc/tut3.md</tutorial>
</tutorials>
```

## Presentation

### Versioning

The user selects the rosdistro they're interested in from a global drop-down
list. This sets a client-side cookie which will persist.

### Tutorials

## Building

```
jekyll build
```

## Deployment

Since this needs to do a lot of heavy lifting to generate the site, it needs to
be deployed from a fully-equipped environment.

```
git checkout source
jekyll build
git branch -D master
git checkout -b master
git add -f _site
git commit -m "deploying"
git filter-branch --subdirectory-filter _site/ -f
git push -f origin master
git checkout source
```

