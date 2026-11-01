FROM python:3.12.11-slim-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 tcpdump \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir "pymodbus[simulator]==3.12.1"

RUN sed -i 's@<iframe name="editor" title="Simulator" src="welcome.html"/>@<iframe name="editor" title="Simulator" src="welcome.html" style="width:100%;height:calc(100vh - 16px);border:0"/>@' /usr/local/lib/python3.12/site-packages/pymodbus/server/simulator/web/index.html

WORKDIR /lab
COPY setup.json /lab/setup.json
COPY node-entrypoint.sh /lab/node-entrypoint.sh
COPY client.py /lab/client.py
COPY tank_plant.py /lab/tank_plant.py
COPY tank_plant_check.py /lab/tank_plant_check.py
RUN chmod +x /lab/node-entrypoint.sh

CMD ["sleep", "infinity"]
