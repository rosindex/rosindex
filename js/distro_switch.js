
$(document).ready(function(){ 
  $('#distro-switch label').click(function (e) {
    console.log(e.target)
    // get the distro and set the cookie
    var distro = $('#'+e.target.id).attr('data');
    console.log(distro);

    if(distro) {
      //$(this).tab('show');
      $('.distro').not('.distro-'+distro).hide(0, function(){
        $('.'+distro).fadeIn('fast');
      });
      //$('.older-distro-button').removeClass('btn-primary');
      console.log(this);
      $('#older-distro-button').removeClass("active");
      $('.older-distro-option').removeClass("active");
      $('#older-label').text('Older');

      $.cookie('rosdistro',distro, {path: '/'});
    }
  })

  $('#distro-switch a').click(function (e) {
    // get the distro and set the cookie
    var distro = $('#'+e.target.id).attr('data');
    $.cookie('rosdistro',distro, {path: '/'});
    console.log(e.target)

    //$(this).tab('show');
    $('.distro').not('.distro-'+distro).hide(0, function(){
      $('.'+distro).fadeIn('fast');
    });

    console.log('#'+distro+'-option');
    $('.distro-button').removeClass("active");
    console.log($('.older-distro-option').not('#'+distro+'-option'))
    $('.older-distro-option').not('#'+distro+'-option').removeClass("active");
    $('#older-distro-button').addClass("active");
    $('#'+distro+'-option').addClass('active');

    $('#older-label').text(distro);
  })

  // set the distro based on cookie
  var distro = $.cookie('rosdistro')
  console.log("preferring "+distro+" distro");
  $('#'+distro+'-option').tab('show');
  $('#'+distro+'-option').addClass('active');
  $('#'+distro+'-button').trigger("click");
});

