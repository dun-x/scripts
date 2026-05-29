# Headscale routes via vps02

Scripts nay dung cho setup Headscale Docker tren `vps01`, route mot so domain/IP rieng qua node `vps02`.

Mac dinh moi script doc config `via-vps02.conf` nam cung thu muc voi chinh file script. Van co the truyen path config rieng lam argument dau tien neu can.

## Files

- `via-vps02.conf.example`: config mau.
- `update-vps02-routes.sh`: chay tren `vps02`, resolve domain va advertise routes.
- `approve-vps02-routes.sh`: chay tren `vps01`, approve routes trong container `headscale`.

## Cai tren vps02

```bash
sudo mkdir -p /opt/headscale-vps02-routes
sudo cp update-vps02-routes.sh via-vps02.conf /opt/headscale-vps02-routes/
sudo chmod 0755 /opt/headscale-vps02-routes/update-vps02-routes.sh
sudo /opt/headscale-vps02-routes/update-vps02-routes.sh
```

Bat forwarding va NAT:

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/99-tailscale-router.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sudo sysctl --system

# Doi eth0 neu public interface cua vps02 co ten khac.
sudo iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || \
  sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

## Cai tren vps01

Copy cung file config sang `vps01`, roi cai script approve:

```bash
sudo mkdir -p /opt/headscale-vps02-routes
sudo cp approve-vps02-routes.sh via-vps02.conf /opt/headscale-vps02-routes/
sudo chmod 0755 /opt/headscale-vps02-routes/approve-vps02-routes.sh
sudo /opt/headscale-vps02-routes/approve-vps02-routes.sh
```

Mac dinh script se tu resolve `NODE_IDENTIFIER=vps02` thanh ID so cua node trong Headscale. Neu can chi dinh ID thu cong:

```bash
docker exec headscale headscale nodes list
sudo NODE_IDENTIFIER=<ID_CUA_VPS02> /opt/headscale-vps02-routes/approve-vps02-routes.sh
```

## Them domain/IP

Sua `via-vps02.conf` trong thu muc script tren ca `vps02` va `vps01`.

```bash
DOMAIN=makeuseof.com
DOMAIN=www.makeuseof.com
DOMAIN=example.com

ROUTE=1.2.3.4/32
ROUTE=8.8.8.0/24
EXTRA_ROUTE=192.168.50.0/24
```

`DOMAIN=` se duoc resolve thanh IPv4 `/32`. `ROUTE=` la route can advertise va approve. `EXTRA_ROUTE=` chi de `vps02` tiep tuc advertise route co san, khong auto approve tren `vps01`.

Luu y: `tailscale set --advertise-routes=...` thay the toan bo danh sach route dang advertise cua `vps02`, nen route nao muon giu phai nam trong config.

## Cron

Tren `vps02`:

```cron
*/30 * * * * /opt/headscale-vps02-routes/update-vps02-routes.sh >/var/log/update-vps02-routes.log 2>&1
```

Tren `vps01`:

```cron
1,31 * * * * /opt/headscale-vps02-routes/approve-vps02-routes.sh >/var/log/approve-vps02-routes.log 2>&1
```

## Test tu client

```bash
tailscale set --accept-routes=true
getent ahostsv4 makeuseof.com
ip route get 54.157.137.27
curl -I https://www.makeuseof.com
```
