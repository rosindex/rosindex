
$(document).ready(function(){ 
  $('#repo-switch a').click(function (e) {
    console.log(e.target)
    // get the distro and set the cookie
    var repo = $('#'+e.target.id).attr('data');
    console.log('selected: '+repo);

    $('.variant').hide(0, function() {
      $('.variant-'+repo).show();
    });
  });
  $('.repo-variant').hide();
})
