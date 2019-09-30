curl -O http://registrationcenter-download.intel.com/akdlm/irc_nas/tec/15553/aws_impi.sh
chmod 755 aws_impi.sh
./aws_impi.sh install
echo "export IMPI_ENV=/opt/intel/impi/2019.4.243/intel64/bin/mpivars.sh" >> ~/.bash_profile
