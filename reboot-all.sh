set -e
set -x
echo "This will reboot every single VM known via 'kcli list vms'.  You"
echo "have 10 seconds to cancel with ctrl-c (^c).  If you do not, then"
echo "all nodes will have 'kcli ssh \$node \"sudo reboot\"' issued."
sleep 10
for i in $(kcli -o name list vms); do kcli ssh $i 'sudo reboot'; done
