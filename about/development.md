---
layout: page
title: Development
permalink: /about/development/
breadcrumbs: ['about']
---

# ROS Index Development

ROS Index is a statically-generated website which is composed of four main components:

1. A Jekyll backbone
2. A Jekyll Ruby plugin which clones and analyzes ROS repositories
3. HTML templates for displaying content
4. Build-side and client-side javascript for searching the index

Everything used to build ROS Index can be found on the [rosindex GitHub
organization](http://github.com/rosindex).

<a href="https://github.com/rosindex/rosindex.github.io/issues/new" target="_blank" class="btn btn-success">Post an Issue</a>

{% toc 2 %}

## Building ROSIndex

### System Requirements

* ruby 1.9
* subversion 1.8
  * with SWIG ruby bindings and serf (`./configure --with-serf`)
* git
* mercurial

### Ruby Requirements

* jekyll
* fileutils
* git
* rexml
* rugged
* nokogiri
* colorize
* typhoeus
* pandoc-ruby
* mercurial-ruby
* svn_wc
* svn/core

### Getting the ROS Index Source

```
git clone --recursive git@github.com:rosindex/rosindex.github.io.git
```

## Building

To build or serve the entire website locally with a handful of ROS packages:

```
rake build:devel
rake serve:devel
```

To build or serve the entire website locally with all known ROS packages:

```
rake build:deploy
rake serve:deploy
```

## Deployment

Deployment is done by simply pushing the generated site to GitHub:

```
cd _deploy
git add .
git commit -a --amend
git push -f origin master
```
