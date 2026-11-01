# DOCSIS PNM proof-of-concept runner

This Containerlab topology runs the locally built `docsis-ns3-poc:ns3.41`
image on a Containerlab host. It provides the ns-3 traffic baseline only.
Synthetic PNM records are not part of this lab.

## Run

The image must exist on the Containerlab host first.

```bash
cd docsis-pnm-poc
sudo -E containerlab deploy -t docsis-pnm-poc.clab.yml
docker logs clab-docsis-pnm-poc-ns3
sudo -E containerlab destroy -t docsis-pnm-poc.clab.yml --cleanup
```

This topology does not emulate DOCSIS RF or generate real PNM measurements.
