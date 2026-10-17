# RMR comes from the NexRAN image the O-RAN profile already has, so its
# version matches the platform; NexRAN is built on Ubuntu 24.04 as well.
ARG RMR_IMAGE=gitlab.flux.utah.edu:4567/powderrenewpublic/nexran/nexran:2.0.0
FROM ${RMR_IMAGE} AS rmr

FROM ubuntu:24.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=rmr /usr/local/lib/librmr_si.so.4.9.4 /usr/local/lib/
RUN ln -s librmr_si.so.4.9.4 /usr/local/lib/librmr_si.so.4 \
    && ln -s librmr_si.so.4 /usr/local/lib/librmr_si.so \
    && ldconfig
RUN pip3 install --no-cache-dir --break-system-packages asn1tools==0.166.0 requests
COPY mobmon.py e2ap-envelope.asn1 e2sm-mob-v01.00.asn1 config-file.json uta_rtg.rt /opt/mobmon/
ENV PYTHONUNBUFFERED=1 RMR_SEED_RT=/opt/mobmon/uta_rtg.rt
CMD ["python3", "/opt/mobmon/mobmon.py"]
