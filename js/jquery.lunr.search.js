(function($) {

  // prevent search from running too often
  var debounce = function(fn) {
    var timeout;
    var slice = Array.prototype.slice;

    return function() {
      var args = slice.call(arguments),
          ctx = this;

      clearTimeout(timeout);

      timeout = setTimeout(function () {
        fn.apply(ctx, args);
      }, 100);
    };
  };

  // parse a date in yyyy-mm-dd format
  var parseDate = function(input) {
    var parts = input.match(/(\d+)/g);
    return new Date(parts[0], parts[1]-1, parts[2]); // months are 0-based
  };

  // define lunr.js search class
  var LunrSearch = (function() {

    function LunrSearch(elem, options) {
      this.$elem = elem;
      this.$results = $(options.results);
      this.$entries = $(options.entries, this.$results);
      this.template = this.compileTemplate($(options.template));
      this.ready = options.ready

      this.indexUrl = options.indexUrl;
      this.indexDataUrl = options.indexDataUrl;

      var self = this;

      this.jxhr = [];

      this.jxhr.push($.getJSON(self.indexUrl, function(serialized_index) {
        console.log("loading " + self.indexUrl);
        self.index = lunr.Index.load(serialized_index);
      }));
      this.jxhr.push($.getJSON(self.indexDataUrl, function(index) {
        console.log("loading " + self.indexDataUrl);
        self.entries = index.entries;
      }));

      $.when.apply($, this.jxhr).done(function() {
        self.populateSearchFromQuery();
        self.bindKeypress();
        self.ready();
        console.log("done loading everything");
      });
    }

      // http://stackoverflow.com/questions/5817811/jquery-multiple-getjson-requests

    // create lunr.js search index
    LunrSearch.prototype.createIndex = function() {
      return lunr(function() {
        this.field('name', { boost: 30 });
        this.field('tags', { boost: 20 });
        this.field('description', { boost: 10 });
        this.field('readme');
        this.field('maintainers');
        this.field('authors');
        this.field('distro');
        this.ref('id');
      });
    };

    // Compile search results template
    LunrSearch.prototype.compileTemplate = function($template) {
      var template = $template.text();
      Mustache.parse(template);
      return function (view, partials) {
        return Mustache.render(template, view, partials);
      };
    };

    // load the search index data
    LunrSearch.prototype.loadIndexData = function(callback) {
    };

    LunrSearch.prototype.loadIndex = function(callback) {
    };

    LunrSearch.prototype.populateIndex = function(data) {
      var index = this.index;

      // format the raw json into a form that is simpler to work with
      this.entries = $.map(data.entries, this.createEntry);

      // add each entry to the index
      $.each(this.entries, function(idx, entry) {
        index.add(entry);
      });
    };

    // reformat the raw json into a simpler format
    LunrSearch.prototype.createEntry = function(raw, index) {
      // add the index from jQuery.map to this object
      // this will be used as a unique identifier for the object
      // this index is 1-based
      var entry = $.extend({
        id: index + 1
      }, raw);

      // include pub date for posts
      if (raw.date) {
        //$.extend(entry, {
          //date: parseDate(raw.date),
          //pubdate: function() {
            //// HTML5 pubdate
            //return dateFormat(parseDate(raw.date), 'yyyy-mm-dd');
          //},
          //displaydate: function() {
            //// only for posts (e.g. Oct 12, 2012)
            //return dateFormat(parseDate(raw.date), 'mmm dd, yyyy');
          //}
        //});
      }

      return entry;
    };

    // Bind the keup to the search function
    //
    // Only re-calls the search function when the value changes and subject to
    // debounce
    LunrSearch.prototype.bindKeypress = function() {
      var self = this;
      var oldValue = this.$elem.val();

      this.$elem.bind('keyup', debounce(function() {
        var newValue = self.$elem.val();
        if (newValue !== oldValue) {
          self.search(newValue);
        }

        oldValue = newValue;
      }));
    };

    // Search function which calls lunr and displays results
    //
    // If the query is too short, it hides the results table, and clears the entries
    // If the query is long enough, it calls lunr and maps the
    LunrSearch.prototype.search = function(query) {
      var entries = this.entries;

      if (query.length < 2) {
        this.$results.hide();
        this.$entries.empty();
      } else {
        // for each search result, grep all the entries for the entry which correpsonds to the result reference
        var results = $.map(this.index.search(query), function(result) {
          return $.grep(entries, function(entry) { return entry.id === parseInt(result.ref, 10); })[0];
        });

        this.displayResults(results);
      }
    };

    // Render the results
    //
    // This will either add a notice or render a template based on the result
    // entries
    LunrSearch.prototype.displayResults = function(entries) {
      var $entries = this.$entries,
          $results = this.$results;

      // clear out the entries
      $entries.empty();

      if (entries.length === 0) {
        $entries.append('<tr><td class="text-center>Nothing found.</td><tr>');
      } else {
        $entries.append(this.template({entries: entries}));
      }

      // show the results element if it isn't already visible
      $results.show();
    };

    // Populate the search input with 'q' querystring parameter if set
    LunrSearch.prototype.populateSearchFromQuery = function() {
      var uri = new URI(window.location.search.toString());
      var queryString = uri.search(true);

      if (queryString.hasOwnProperty('q')) {
        this.$elem.val(queryString.q);
        this.search(queryString.q.toString());
      }
    };

    return LunrSearch;
  })();


  $.fn.lunrSearch = function(options) {
    // apply default options
    options = $.extend({}, $.fn.lunrSearch.defaults, options);

    // create search object
    new LunrSearch(this, options);

    return this;
  };


  $.fn.lunrSearch.defaults = {
    indexUrl  : '/search.json',     // Url for the .json file containing search index source data (containing: title, url, date, body)
    results   : '#search-results',  // selector for containing search results element
    entries   : '.entries',         // selector for search entries containing element (contained within results above)
    template  : '#search-results-template'  // selector for Mustache.js template
  };
})(jQuery);
