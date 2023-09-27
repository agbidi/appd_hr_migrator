# appd_hr_manager
A script that does migrations of AppDynamics Health Rule Configuration via the AppD API

Usage: appd_hr_migrator.sh [-h] [-v] -m export|import -c config_file

Migrate AppDynamics Health Rules

Available options:

-h, --help        Print this help and exit<br>
-v, --verbose     Print script debug info<br>
-m, --mode        Export or Import<br>
-c, --config      Path to config file<br>

Example:

./appd_hr_migrator.sh -m export -c appd_prod.cfg

Content of the config file:

appd_src_url='https://srcaccount.saas.appdynamics.com' # appd controller url<br>
appd_src_account='srcaccount' # appd account<br>
appd_src_api_user='api_user' # appd api username<br>
appd_src_api_secret='' # appd api secret to retrieve appd oauth token. Set as empty string to enable basic authentication<br>
appd_src_api_password='' # appd api password for basic authentication. Set as empty string if using appd oauth authentication<br>
appd_src_proxy='http://proxy.url:80'

appd_dst_url='https://dstaccount.saas.appdynamics.com' # appd controller url<br>
appd_dst_account='dstaccount' # appd account<br>
appd_dst_api_user='api_user' # appd api username<br>
appd_dst_api_secret='' # appd api secret to retrieve appd oauth token. Set as empty string to enable basic authentication<br>
appd_dst_api_password='' # appd api password for basic authentication. Set as empty string if using appd oauth authentication<br>
appd_dst_proxy='http://proxy.url:80'

appd_application_names='.*' # app names regex<br>
output_dir='./output' # output dir <br>
overwrite='true' # overwrite health rules on import
