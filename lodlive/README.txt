We used lodlive for visualization.
http://en.lodlive.it/
The code is available through github at: https://github.com/dvcama/LodLive

To get the lodlive point to d2rq, here are the steps I took.

When using the git cloned copy, copy js/lodlive.profile-localhost-example.js to js/lodlive.profile.js
If you are using the included zip file, you don't need to do that.

Change the connection settting:
  Change 'http://' to your hostname.
    In our demo, we used 'http://lib-dev-020.serverfarm.cornell.edu:8080'
  Change endpoint to your hostname.
    In our demo, we used 'http://lib-dev-020.serverfarm.cornell.edu:8080/d2rq/sparql'

# I am not sure if this is necessary
Change the default setting:
  Change endpoint to your hostname.
    In our demo, we used 'http://lib-dev-020.serverfarm.cornell.edu:8080/d2rq'


The included zip file is the lodlive code we used for the Tech Innovation
demo.
