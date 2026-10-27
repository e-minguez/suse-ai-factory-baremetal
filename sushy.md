# sushy-tools

## Running the sushy-emulator as a container on SLES/openSUSE

### Prerequisites

* SLES or openSUSE host with libvirt
* Podman with Quadlet support (Podman ≥ 4.4)
* `qemu-ovmf-x86_64` ([package](https://software.opensuse.org/package/qemu-ovmf-x86_64)):
  the config below maps UEFI boot to `/usr/share/qemu/ovmf-x86_64-ms-code.bin`
  and the container bind-mounts it, so it is required.
  That firmware has the Microsoft keys enrolled: VMs boot with Secure Boot
  enabled (`DeployedMode`), so the OS image must boot via a signed shim.

```bash
zypper install qemu-ovmf-x86_64
```

### Preparation

1. Create the `/etc/sushy/` folder to store the configuration and certificates:

   ```bash
   mkdir -p /etc/sushy/
   cd /etc/sushy/
   ```

   TLS is optional for Metal3 (`redfish-virtualmedia://` works over https with
   `disableCertificateVerification: true` in the BMH), but some clients require
   it, e.g. the Ansible [`redfish_command` module](https://github.com/ansible-collections/community.general/blob/main/plugins/modules/redfish_command.py#L851C5-L851C13)
   always builds an `https://` root URI:

   ```python
   # Build root URI
   root_uri = "https://" + module.params['baseuri']
   ```

2. Create the certificate and key (passwordless, 10 years validity: fine for a
   lab, not for production):

   ```bash
   openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
       -subj "/C=ES/ST=Madrid/L=Las Rozas/O=Foo/CN=sushy-emulator" \
       -keyout sushy-emulator.key -out sushy-emulator.crt
   ```

3. Create the config file:

   ```bash
   cat << EOF > /etc/sushy/sushy-emulator.conf
   SUSHY_EMULATOR_LISTEN_IP = '0.0.0.0'
   SUSHY_EMULATOR_LISTEN_PORT = 8443
   SUSHY_EMULATOR_SSL_CERT = '/etc/sushy/sushy-emulator.crt'
   SUSHY_EMULATOR_SSL_KEY = '/etc/sushy/sushy-emulator.key'
   SUSHY_EMULATOR_OS_CLOUD = None
   SUSHY_EMULATOR_LIBVIRT_URI = 'qemu:///system'
   # Must be False for Metal3: with True, sushy ignores Ironic's boot device
   # requests and UEFI boots the installed OS instead of the IPA ISO, so
   # cleaning and redeploys hang (first inspection/deploy still work on empty disks)
   SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False
   SUSHY_EMULATOR_BOOT_LOADER_MAP = {
       'UEFI': {
           'x86_64': '/usr/share/qemu/ovmf-x86_64-ms-code.bin'
       },
       'Legacy': {
           'x86_64': None
       }
   }
   EOF
   ```

   > **Note — authentication:** this config sets no `SUSHY_EMULATOR_AUTH_FILE`,
   > so sushy accepts **any** username/password. The credentials in the BMH
   > Secrets (`bmh/*.yaml`) are sent but never checked. To enforce them, create
   > an htpasswd file (bcrypt) and set
   > `SUSHY_EMULATOR_AUTH_FILE = '/etc/sushy/htpasswd'`.

4. Create a Quadlet unit for the container:

   ```bash
   cat << 'EOF' > /etc/containers/systemd/sushy-emulator.container
   [Unit]
   Description=sushy-tools Redfish emulator
   Wants=network-online.target
   After=network-online.target

   [Container]
   ContainerName=sushy-emulator
   Image=quay.io/metal3-io/sushy-tools:latest
   Exec=sushy-emulator
   # Host network is required: on the podman bridge, sushy's traffic to Ironic
   # (virtual media ISO download) is forwarded into virbr0 and rejected by
   # libvirt's NAT rules ("Connection refused")
   Network=host
   PodmanArgs=--privileged
   Volume=/etc/sushy:/etc/sushy:ro
   Volume=/var/run/libvirt:/var/run/libvirt
   Volume=/usr/share/qemu/ovmf-x86_64-ms-code.bin:/usr/share/qemu/ovmf-x86_64-ms-code.bin:ro
   Volume=/etc/localtime:/etc/localtime:ro
   Environment=SUSHY_EMULATOR_CONFIG=/etc/sushy/sushy-emulator.conf

   [Service]
   Restart=always
   # Restart once a day to clean up /tmp, which fills up with virtual media
   # images: https://storyboard.openstack.org/#!/story/2011064
   RuntimeMaxSec=1d

   [Install]
   WantedBy=multi-user.target
   EOF
   ```

   No `-p 8443:8443`/`PublishPort`: published ports have no effect with host
   networking.

5. Generate the service from the Quadlet file and start it (Quadlet units are
   enabled through their `[Install]` section; `systemctl enable` does not apply):

   ```bash
   systemctl daemon-reload
   systemctl start sushy-emulator
   systemctl status sushy-emulator
   ```

6. Open 8443/tcp if needed. The VMs and the management cluster reach the
   hypervisor through `virbr0`, which firewalld normally places in the `libvirt`
   zone (not `public`):

   ```bash
   firewall-cmd --get-zone-of-interface=virbr0
   firewall-cmd --zone=libvirt --add-port=8443/tcp --permanent
   firewall-cmd --zone=libvirt --add-port=8443/tcp
   ```

   Do the same for the port serving the OS image (e.g. `8000/tcp`). Use
   `--zone=public` for clients outside the libvirt network.

### Testing

```bash
curl https://localhost:8443/redfish/v1/Systems
curl: (60) SSL certificate problem: self signed certificate
More details here: https://curl.se/docs/sslcerts.html

curl failed to verify the legitimacy of the server and therefore could not
establish a secure connection to it. To learn more about this situation and
how to fix it, please visit the web page mentioned above.
```

Ignoring the certificate:

```bash
curl -k https://localhost:8443/redfish/v1/Systems
{
    "@odata.type": "#ComputerSystemCollection.ComputerSystemCollection",
    "Name": "Computer System Collection",
    "Members@odata.count": 6,
    "Members": [
            {
                "@odata.id": "/redfish/v1/Systems/1a3cc749-dd03-4f2b-a588-981c8fbf2911"
            },
            ...
    ],
    "@odata.context": "/redfish/v1/$metadata#ComputerSystemCollection.ComputerSystemCollection",
    "@odata.id": "/redfish/v1/Systems",
    "@Redfish.Copyright": "Copyright 2014-2016 Distributed Management Task Force, Inc. (DMTF). For the full DMTF copyright policy, see http://www.dmtf.org/about/policies/copyright."
}
```

Systems are also reachable by libvirt domain name (redirects to the UUID), which
is what the BMHs use:

```bash
curl -k https://localhost:8443/redfish/v1/Systems/vm-cp-01
```

Check that boot device requests are honoured (during an IPA boot the cdrom gets
a per-device boot order; `<boot dev='fd'/>` under `<os>` means
`IGNORE_BOOT_DEVICE` is still `True`):

```bash
virsh dumpxml vm-cp-01 | grep -E "<boot|boot order"
```
