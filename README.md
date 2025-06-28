# workr

## What is this project

A few quick and dirty scripts to make it easier to set up an R cluster for running parallel data analyses (e.g. with parallel, future, furrr, etc).

## What does it do?

1. Install a bunch of packages (including Avahi for dDNS, Clevis for policy-based decryption, Docker, Tailscale, and the qemu guest agent)
2. Set up and run a docker-compose file for a Rocker image including most of the packages you might ever need, and any extras that you ask for
3. Set a unique hostname and machine ID
4. Set a unique static IP address
5. Change the Login and LUKS passwords to something unique you provide
6. Change the LUKS volume key (so getting into one worker doesn't compromise encryption on all the workers
7. Set up Clevis for policy-based decryption of your LUKS volume (automatic unlock - you'll need to provide your own infrastructure for this, such as Tang servers)

## Is this a good idea?

I'll report back to you on that one. But if you just want to have a go running your slow, parallel R analyses on a bunch of computers, this should be a relatively quick way to get through the devops problems and into the programming problems.

## What do I need?

- Some way to clone an ubuntu install and spin up a bunch of worker VMs. I'm using Proxmox, but there's no reason it wouldn't work with other hypervisors or even just cloning images onto bare metal.
- Some way to connect to the workers (e.g. ssh, serial terminal, emulated vga)
- An internet connection during setup to download the script, packages, etc
- Tang servers or some other kind of device to secure Clevis

## How do I do it?

### 1. Install Ubuntu

For this project I've used Ubunut 22.04 Server (Minimised) LTS. Go grab the ISO, and install it in the usual way. 
I've given my VMs 4 cores, 32GB of disk space, and 8GB of RAM, but those were completely arbitrary choices. 
I've installed with mostly default options, except for selecting a minimized install, using LUKS2 for full disk encryption, and pre-importing my pubkey for SSH access.
Don't set any static IP - just leave it with DHCP.
You can set 'weak' passwords for login and LUKS, we'll be changing them later.

### 2. Clone your base machine

Do in the usual way for your hypervisor. In Proxmox, I just right click the VM and select 'clone', then tick a couple options. 

#### 3. Connect to your new clone

It's handy to run ```ip addr``` on the new machine in your hypervisor so you know where to ssh to.

### 4. Paste in a couple terminal commands

You will need to provide values for various parameters at the command line, then grab and run the init script. You're basically creating a bunch of little tiny files in your home folder, but the script will delete them later.

#### Parameters

| Parameter     | Content                                        | Example                                                                                                                  |
| ------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| old.pw        | Default LUKS password for the template         | template                                                                                                                 |
| new.pw        | Unique new LUKS password                       | wretched*smog8INDULGE_shanghai                                                                                           |
| login.pw      | Unique new login password                      | COPSE_fraternity4red@lozenge                                                                                             |
| hostname.txt  | Unique new hostname                            | workr1                                                                                                                   |
| ip.txt        | Unique new static IP                           | 192.168.64.1/16                                                                                                          |
| dns.txt       | Default DNS                                    | 192.168.1.1                                                                                                              |
| key.pub       | A pubkey e.g. for your RServer host            | ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILsk1UwzbKedxn+qassB4ShQDoDGEYs4q1Qi6DpmiVW9 rserver@serve-r.local                   |
| key.url       | A url to grab a key from e.g. for your dev box | https://github.com/exampleuser.keys                                                                                          |
| R.pkgs        | Extra packages to install on the worker        | c(\"future\", \"furrr\")                                                                                                 |
| clevis.policy | Clevis policy for automatic LUKS Unlock        | {"t":2, "pins":{ "tang":[{"url":"http://192.168.32.1"}, {"url":"http://192.168.32.2"}, {"url":"http://192.168.32.3"}}]}} |

#### Example Terminal Commands

``` terminal
echo -n "template" > old.pw
echo -n "wretched*smog8INDULGE_shanghai" > new.pw
echo -n "COPSE_fraternity4red@lozenge" > login.pw
echo -n "workr1" > hostname.txt
echo -n "192.168.64.1/16" > ip.txt
echo -n "192.168.1.1" > dns.txt
echo -n "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILsk1UwzbKedxn+qassB4ShQDoDGEYs4q1Qi6DpmiVW9 rserver@serve-r.local" > key.pub
echo -n "https://github.com/exampleuser.keys" > key.url
echo -n "c(\\\"future\\\", \\\"furrr\\\")" > R.pkgs
cat > clevis.policy << EOF
{"t":2,
  "pins":{
    "tang":[
      {"url":"http://192.168.3.247"},
      {"url":"http://192.168.3.248"},
      {"url":"http://192.168.3.249"},
      {"url":"http://192.168.3.250"}
    ]
  }
}
EOF
ip route show default | awk '{print $5}' > interface.txt
curl https://raw.githubusercontent.com/maashaw/workr/refs/heads/main/init.sh -o init.sh
chmod +x ./init.sh
./init.sh
```

### 5. Wait

It takes a bit of time to run - in particular, to change the volume key, This takes a while because it has to decrypt then re-encrypt the whole disk - IO is usually more of a bottleneck than the crypto operations on modern CPUs with AES instructions, so it'll probably take about as long as it took to clone your machine. Depending on the speed of your internet connection, it might also take some time to set up the docker container (R Geospatial is about 1.6GB). 

### 6. Set up your Cluster

On your R machine, you'll need to create an cluster object as shown below. You'll need to modify this to fit your setup, but this code here will run 4 threads on the current machine, and 4 threads on each of the five workers specified here. It assumes that the workers are accessible for passwordless ssh connections on port 2222.

``` R
cl <- makeClusterPSOCK(c(rep("localhost", 4), 
                         rep("rstudio@192.168.64.1",4),
                         rep("rstudio@192.168.64.2",4),
                         rep("rstudio@192.168.64.3",4),
                         rep("rstudio@192.168.64.4",4),
                         rep("rstudio@192.168.64.5",4)),
                       rshcmd = c("ssh"), rshopts = c("-p", "2222"))
plan(future::cluster, workers = cl)
```

You should now be able to run parallel analyses (e.g. with furrr, future, etc) on your cluster!

## Notes

### Security
This does not substitue for a data protection risk assessment, and is provided for general information only; if you need solid answers, review the script and how you're implementing your cluster.

The risk model for this solution assumes that you are running these workers in on a protected network in a virtualisation environment running on hardware that you control. The use of full-disk encryption with unique keys and depending on tang servers for automatic unlocking means that they should be secure at rest, e.g. if someone breaks in and steals the computers your cluster runs on, and protection against unplanned redistribution of your hardware is the main threat hardened against.

I'm sure this doesn't need to be spelled out, but if you're running this on hardware you don't control (e.g. in a cloud), you MUST trust that the operator isn't nefarious (e.g. won't snoop unencrypted data out of the virtual machine's RAM, subvert your disk images or install media, MITM your traffic, etc, etc, etc). 

Sensitive data including credentials etc get saved to the worker's home directory to facilitate the init script; but this should be a 'clean' template with full disk encryption, and the files are securely deleted afterwards, so the actual risk of this approach is probably very small.

The workers *should* be stateless, which is to say they should not store data from any tasks sent to them after they return their results. I have not verified this, and e.g. if a VM crashes and produces a crash dump, job data may be included. You could snapshot the workers immediately after setup and regularly revert to the original snapshot if you need to deal with the risk of the workers storing protected data between uses.

The workers should only be accessible over SSH on port 22 (for the host) and port 2222 (for the worker container), and through the container's web interface (on 80). However, the web interface has a terminal, root within the container, and has a default password. If you aren't running it within a secure environment, you will want to disable the web interface; how you do this is an exercise left to the reader. You could at least modify the script to allow you to set strong, unique keys for each worker, or set a firewall rule to limit access to only port 22 and 2222.

### Maintainance
You should hopefully not need to connect to the hosts again after running the init script; however, you should be able to connect over ssh then ```cd ~/rstudio``` to amend the docker container configuration with ```nano docker-compose.yml```, and reload the container using ```sudo docker compose down && docker compose up```.

You should also be able to reach the rstudio container directly by putting the worker's IP into your browser; the default username and password are specified in the init script.

### Port Numbers
Port 2222 is specified in the docker-compose that the init script writes out; you can change it if you need to use a different port. Why can't it just be regualar port 22, like we did to set the worker up? Because R is running in a docker container, so we need to connect to the docker container, not the worker which is hosting the docker container.

### Containers
I've specified rocker/geospatial:4.4.2 in the init script. If you need a different image, clone this repo and modify the init script. If you need to install additional packages, you can specify a list in R.pkgs (see information above about the parameters).

### Other FAQs
- Why can't you set up the container once, before you clone it?
  -  ~~Because I didn't think of that at the time~~
  - For flexibility, so it's generic and you can use whatever container you want.
  - You could even completely repurpose this script to e.g. set up a cluter of jellyfin servers or something.
  - Why not clone this repo and show me your cool ideas?
-  Why don't you use Hashicorp Vault / Docker Secrets / this neat auth solution
  - I wrote this in a couple hours to solve a problem I don't expect to have very often
  - Why not send me a pull request?
- How do I set up Tailscale on the worker nodes?
  - This is left as an exercise for the reader.
  - You can comment out the relevent lines from the script if you don't need it, and save a couple megabytes.

### Example Values
The example values above, including network addresses, credentials, etc are all made up. They won't work off the shelf, but they're easy to tailor to your environment.

## No Warranties
This is provided as-is in good faith in the hope that it's useful, but at the end of the day it's free code some random guy wrote that you found on the internet, and if it burns down your house, steals your dog, and vomits your customer data all over bittorrent you that's a you problem (and you agree to fully indemnify and hold me innocent against your foolishness).

## Bugs and Security Disclosures
Please contact directly me if you identify any critical security vulnerabilities, and I'll try to fix it quick.
If you notice any other bugs or problems, raise an issue or send a pull request.

## See Also
[Parallel Package Documentation](https://search.r-project.org/R/refmans/parallel/html/00Index.html) [Future](https://future.futureverse.org) [Furrr](https://furrr.futureverse.org/index.html)
[Rocker Project](https://rocker-project.org) [Rocker Repo](https://github.com/rocker-org/geospatial)
[Tailscale](https://tailscale.com)
[Docker](https://www.docker.com)
[Clevis Repo](https://github.com/latchset/clevis)
