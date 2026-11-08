# Lambda with the Lambda Web Adapter

Files: `Dockerfile`, `template.yaml` (SAM), and [`../puma.rb`](../puma.rb) (copy it to `config/puma.rb`).

[Lambda Web Adapter](https://github.com/aws/aws-lambda-web-adapter) (LWA) runs as a Lambda extension and forwards invocations to the web server in the container. The image copies it from `public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0` and works with a non-Lambda base image such as `ruby:3.4.7-slim` [L6]. [Lamby](https://lamby.cloud) is an alternative that runs a Rack adapter on the Lambda Ruby base image. There is no template for it here.

What the settings do:

| Setting | Where | Effect |
| --- | --- | --- |
| `AWS_LWA_PORT=3000` | `Dockerfile` | the port LWA forwards to (default 8080) [L6] |
| `AWS_LWA_READINESS_CHECK_PATH=/up` | `Dockerfile` | LWA polls this path until it succeeds before the first invoke (default `/`) [L7] |
| `AWS_LWA_ASYNC_INIT=true` (commented) | `Dockerfile` | use it if boot can exceed about 9.8 s, so the 10 s Init limit is not hit [L7, L1] |
| `MemorySize: 1769` | `template.yaml` | one vCPU. Lambda allocates CPU in proportion to memory |
| `AuthType: AWS_IAM` | `template.yaml` | the Function URL requires SigV4. `NONE` makes it public |
| `bootsnap precompile` | `Dockerfile` | cache built at image build |

Limits to know:

- Init is limited to 10 s and is billed [L1, L2].
- SnapStart does not support Ruby [L3]. Lambda Managed Instances do not support Ruby [L4].
- Lambda may initialize an environment before a request arrives (proactive init) [L1]. The recorder logs the gap as `idle`; `hayaoki cold-start-report --exclude-proactive` drops lines with a gap over 1000 ms.
- The file system is read-only except `/tmp`. The Dockerfile sets `BOOTSNAP_READONLY=1`, so bootsnap reads the cache precompiled at build in `/rails/tmp/cache/bootsnap` and does not try to write it (bootsnap 1.17+; stale entries fall back to compiling in memory).

## Steps

1. Add the gem and the `config/boot.rb` lines from [`../README.md`](../README.md#add-the-recorder-to-your-app). Make sure `/up` returns 2xx.
2. Copy `Dockerfile`, `template.yaml` and `puma.rb` (to `config/puma.rb`) into the app root.
3. `sam build && sam deploy --guided`. Pass `SecretKeyBase` as a parameter.
4. Invoke the Function URL (signed with SigV4, for example `curl --aws-sigv4 "aws:amz:REGION:lambda" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" URL`).
5. Collect the lines and summarize:

```sh
aws logs filter-log-events --log-group-name /aws/lambda/FUNCTION \
  --filter-pattern '{ $.hayaoki = "cold_start" }' > cold.json
hayaoki cold-start-report --group-by init_type cold.json
```

`cold-start-report` reads the CloudWatch JSON (the `message` strings). Lambda `REPORT` lines in the same input are counted as `platform_init_ms` (`Init Duration`); to include them, also fetch the `REPORT` lines (`--filter-pattern REPORT`) into the same file or stdin.
