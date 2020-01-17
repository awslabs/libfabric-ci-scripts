curl -O http://registrationcenter-download.intel.com/akdlm/irc_nas/tec/16120/l_mpi_2019.6.166.tgz
tar -zxf l_mpi_2019.6.166.tgz
cd l_mpi_2019.6.166
sed -e "s/decline/accept/" silent.cfg > accept.cfg
sudo ./install.sh -s accept.cfg
