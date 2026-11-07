#!/usr/bin/env bash
# MathPad class server on Oracle's free Ampere machine — keeps trying until Oracle has room.
#
# Run in Oracle Cloud Shell (the >_ icon at the top of the Oracle console), after uploading
# this file and install.sh (⚙ / ⋮ menu → Upload):
#
#   bash oracle-retry.sh                         # 2 OCPU / 12 GB, retries every 60 s
#   bash oracle-retry.sh 1 6                     # smaller: 1 OCPU / 6 GB (easier to get)
#   bash oracle-retry.sh 2 12 mathpadclass TOKEN # …and when it gets one, points
#                                                #    mathpadclass.duckdns.org at it and installs LiveKit
#
# It makes (once) a network "mathpad-vcn" with the class ports open, then asks Oracle for the
# machine every minute until it gets one. Safe to run again if Cloud Shell closes: it carries on.
# Everything it creates is Always Free.
set -uo pipefail

OCPUS="${1:-2}"; MEM="${2:-12}"
DUCK="${3:-}"; TOKEN="${4:-}"
WAIT="${WAIT:-60}"
NAME=mathpad-class
KEY="$HOME/.ssh/mathpad"

say() { echo "$(date +%H:%M:%S)  $*"; }

# ---------------------------------------------------------------- where
TEN="${OCI_TENANCY:-}"
if [ -z "$TEN" ]; then
  TEN="$(oci iam compartment list --all --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)"
fi
if [ -z "$TEN" ] || [ "$TEN" = "null" ]; then
  echo "Couldn't find your tenancy. Run:  export OCI_TENANCY=ocid1.tenancy...  (Profile menu → Tenancy → OCID) and try again."; exit 1
fi
AD="$(oci iam availability-domain list -c "$TEN" --query 'data[0].name' --raw-output)"
say "Region ${OCI_REGION:-?} · $AD · ${OCPUS} OCPU / ${MEM} GB"

# ---------------------------------------------------------------- already there?
EXIST="$(oci compute instance list -c "$TEN" --display-name "$NAME" --query "data[?\"lifecycle-state\"!='TERMINATED'] | [0].id" --raw-output 2>/dev/null)"

# ---------------------------------------------------------------- ssh key (lives in Cloud Shell)
if [ ! -f "$KEY" ]; then
  mkdir -p "$HOME/.ssh"; ssh-keygen -t ed25519 -N "" -q -f "$KEY"
  say "Made an SSH key in Cloud Shell ($KEY)"
fi

# ---------------------------------------------------------------- network with the class ports
VCN="$(oci network vcn list -c "$TEN" --display-name mathpad-vcn --query "data[?\"lifecycle-state\"=='AVAILABLE'] | [0].id" --raw-output 2>/dev/null)"
if [ -z "$VCN" ] || [ "$VCN" = "null" ]; then
  say "Making the network mathpad-vcn…"
  VCN="$(oci network vcn create -c "$TEN" --cidr-block 10.0.0.0/16 --display-name mathpad-vcn --dns-label mathpad --wait-for-state AVAILABLE --query data.id --raw-output 2>/dev/null | grep '^ocid1' | tail -1)"
  IGW="$(oci network internet-gateway create -c "$TEN" --vcn-id "$VCN" --is-enabled true --display-name mathpad-igw --wait-for-state AVAILABLE --query data.id --raw-output 2>/dev/null | grep '^ocid1' | tail -1)"
  RT="$(oci network vcn get --vcn-id "$VCN" --query 'data."default-route-table-id"' --raw-output)"
  oci network route-table update --rt-id "$RT" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" >/dev/null
fi
SL="$(oci network vcn get --vcn-id "$VCN" --query 'data."default-security-list-id"' --raw-output)"
tcp() { echo "{\"source\":\"0.0.0.0/0\",\"protocol\":\"6\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":$1,\"max\":$2}}}"; }
udp() { echo "{\"source\":\"0.0.0.0/0\",\"protocol\":\"17\",\"udpOptions\":{\"destinationPortRange\":{\"min\":$1,\"max\":$2}}}"; }
RULES="[$(tcp 22 22),$(tcp 80 80),$(tcp 443 443),$(tcp 7881 7881),$(udp 3478 3478),$(udp 50000 60000),{\"source\":\"0.0.0.0/0\",\"protocol\":\"1\",\"icmpOptions\":{\"type\":3,\"code\":4}}]"
oci network security-list update --security-list-id "$SL" --force \
  --ingress-security-rules "$RULES" \
  --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all"}]' >/dev/null && say "Class ports open (80, 443, 7881, 3478, 50000-60000)"
SUBNET="$(oci network subnet list -c "$TEN" --vcn-id "$VCN" --query 'data[0].id' --raw-output 2>/dev/null)"
if [ -z "$SUBNET" ] || [ "$SUBNET" = "null" ]; then
  SUBNET="$(oci network subnet create -c "$TEN" --vcn-id "$VCN" --cidr-block 10.0.0.0/24 --display-name mathpad-public --dns-label pub --wait-for-state AVAILABLE --query data.id --raw-output 2>/dev/null | grep '^ocid1' | tail -1)"
fi

# ---------------------------------------------------------------- the machine
if [ -n "$EXIST" ] && [ "$EXIST" != "null" ]; then
  ID="$EXIST"; say "The server $NAME already exists."
else
  IMG="$(oci compute image list -c "$TEN" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
          --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output)"
  [ -n "$IMG" ] && [ "$IMG" != "null" ] || { echo "Couldn't find the Ubuntu 24.04 image."; exit 1; }
  TRY=0
  while true; do
    TRY=$((TRY + 1))
    OUT="$(oci compute instance launch -c "$TEN" --availability-domain "$AD" --display-name "$NAME" \
            --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" \
            --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true \
            --ssh-authorized-keys-file "$KEY.pub" --query data.id --raw-output 2>&1)"
    ID="$(echo "$OUT" | grep -o 'ocid1\.instance[^" ]*' | head -1)"
    if [ -n "$ID" ]; then say "Got it on try $TRY!"; break; fi
    if echo "$OUT" | grep -qi 'capacity'; then
      say "Try $TRY: Oracle has no free machine yet — trying again in ${WAIT}s (keep this tab open)"
      sleep "$WAIT"; continue
    fi
    if echo "$OUT" | grep -qi 'TooManyRequests\|429'; then
      say "Oracle asked us to slow down — waiting 3 minutes"; sleep 180; continue
    fi
    if echo "$OUT" | grep -qi 'LimitExceeded'; then
      echo "Oracle says the free limit is used (maybe a failed server from the console is still there)."
      echo "In the console: Compute → Instances — terminate any extra instance, then run this again."; exit 1
    fi
    echo "Oracle said:"; echo "$OUT"; exit 1
  done
fi

say "Waiting for the server to start…"
oci compute instance get --instance-id "$ID" --wait-for-state RUNNING >/dev/null 2>&1
IP="$(oci compute instance list-vnics --instance-id "$ID" --query 'data[0]."public-ip"' --raw-output)"
say "Server running · public IP: $IP"

if [ -z "$DUCK" ] || [ -z "$TOKEN" ]; then
  echo
  echo "Next: point your DuckDNS name at $IP, then run here:"
  echo "  scp -i $KEY -o StrictHostKeyChecking=accept-new install.sh ubuntu@$IP:~ && ssh -i $KEY ubuntu@$IP 'sudo bash ~/install.sh YOURNAME.duckdns.org'"
  exit 0
fi

DUCK="${DUCK%.duckdns.org}"
R="$(curl -s "https://www.duckdns.org/update?domains=$DUCK&token=$TOKEN&ip=$IP")"
[ "$R" = "OK" ] && say "$DUCK.duckdns.org → $IP" || { echo "DuckDNS said: $R (check the name and token)"; exit 1; }
[ -f install.sh ] || { echo "Upload install.sh to Cloud Shell, then run this again."; exit 1; }
sed -i 's/\r$//' install.sh
say "Waiting for SSH…"
for i in $(seq 1 40); do
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 ubuntu@"$IP" true 2>/dev/null && break
  sleep 8
done
scp -i "$KEY" -o StrictHostKeyChecking=accept-new install.sh ubuntu@"$IP":~/install.sh
# keep the DuckDNS name pointed at the server
ssh -i "$KEY" ubuntu@"$IP" "echo '*/5 * * * * root curl -s \"https://www.duckdns.org/update?domains=$DUCK&token=$TOKEN&ip=\" >/dev/null' | sudo tee /etc/cron.d/duckdns >/dev/null"
say "Installing LiveKit (3–5 minutes)…"
ssh -i "$KEY" ubuntu@"$IP" "sudo bash ~/install.sh $DUCK.duckdns.org"
