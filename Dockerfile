# spm_biascorr on top of the official SPM standalone image (MATLAB Runtime,
# no MATLAB licence needed). SPM itself is not redistributed here, it comes
# from the base image.
#
# Build:  docker build -t spm_biascorr .
#         docker build --build-arg SPM_IMAGE=ghcr.io/spm/spm-docker:docker-matlab-latest -t spm_biascorr:latest .
# Run:    docker run --rm -u $(id -u):$(id -g) -v $PWD:/data spm_biascorr in.nii.gz out.nii.gz [bias.nii.gz]

ARG SPM_IMAGE=ghcr.io/spm/spm-docker:docker-matlab-25.01.02
FROM ${SPM_IMAGE}

COPY spm_biascorr.sh /usr/local/bin/spm_biascorr.sh

# the SPM images link the standalone executable to /usr/local/bin/spm,
# create that link if a base image does not
RUN chmod 755 /usr/local/bin/spm_biascorr.sh \
    && if [ ! -x /usr/local/bin/spm ]; then \
         ln -s "$(find /opt -maxdepth 2 -type f -perm -u+x -name 'spm[0-9]*' ! -name '*.*' | head -n 1)" /usr/local/bin/spm; \
       fi \
    && test -x /usr/local/bin/spm

ENV SPM_STANDALONE=/usr/local/bin/spm

WORKDIR /data
ENTRYPOINT ["/usr/local/bin/spm_biascorr.sh"]
CMD ["--help"]
