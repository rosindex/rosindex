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

* ruby 2.2
* rubygems
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

### Skipping Parts of the Build

The build process entails four long-running steps:

1. Generating the list of repositories
2. Cloning / Updating the known repositories
3. Scraping the repositories
4. Generating the static pages
5. Generating the lunr search index

Each of the first three steps can be skipped in order to save time when
experimenting with different parts of the pipeline with the following flags in
`_config.yml`:

```yaml
# If true, this skips finding repos based on the repo sources
skip_discover: false
# If true, this skips updating the known repos
skip_update: false
# If true, this skips scraping the cloned repos
skip_scrape: false
# If true, this skips generating the search index
skip_search_index: false
```

## Deployment

Deployment is done by simply pushing the generated site to GitHub:

```
cd _deploy
git add .
git commit -a --amend
git push -f origin master
```

## Design Patterns

### Pagination

Currently, pagination of `N` total items is done by generating html files for
each page of `n` items and each `m` ways of sorting those items. This leads to
`n*(m+1)` html pages (`+1` for the default sort, whichever that may be). This
also constrains the display to display only `N/n` items at a time.

*Goal:* Make it easier to generate 
