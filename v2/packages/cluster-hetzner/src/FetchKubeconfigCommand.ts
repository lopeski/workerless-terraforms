import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";

export interface FetchKubeconfigCommandArgs {
  readonly bootstrapPublicIp: pulumi.Input<string>;
  readonly sshPrivateKeyPath: string;
}

export class FetchKubeconfigCommand extends pulumi.ComponentResource {
  public readonly kubeconfig: pulumi.Output<string>;
  public readonly kubeHost: pulumi.Output<string>;
  public readonly kubeCa: pulumi.Output<string>;
  public readonly kubeClientCert: pulumi.Output<string>;
  public readonly kubeClientKey: pulumi.Output<string>;

  constructor(
    name: string,
    args: FetchKubeconfigCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:cluster:FetchKubeconfigCommand", name, {}, opts);

    const connection: command.types.input.remote.ConnectionArgs = {
      host: args.bootstrapPublicIp,
      user: "root",
      privateKey: pulumi.secret(
        require("fs").readFileSync(args.sshPrivateKeyPath, "utf8") as string,
      ),
    };

    const fetchKubeconfig = new command.remote.Command(
      `${name}-fetch`,
      {
        connection,
        create: "cat /etc/rancher/k3s/k3s.yaml",
      },
      { parent: this },
    );

    const publicIp = pulumi.output(args.bootstrapPublicIp);

    this.kubeconfig = pulumi.all([fetchKubeconfig.stdout, publicIp]).apply(
      ([raw, ip]) => raw.replace("127.0.0.1", ip),
    );

    const parsedCa = new command.remote.Command(
      `${name}-ca`,
      {
        connection,
        create: "k3s kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'",
      },
      { parent: this },
    );

    const parsedCert = new command.remote.Command(
      `${name}-cert`,
      {
        connection,
        create: "k3s kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}'",
      },
      { parent: this },
    );

    const parsedKey = new command.remote.Command(
      `${name}-key`,
      {
        connection,
        create: "k3s kubectl config view --raw -o jsonpath='{.users[0].user.client-key-data}'",
      },
      { parent: this },
    );

    this.kubeHost = publicIp.apply((ip) => `https://${ip}:6443`);
    this.kubeCa = pulumi.secret(parsedCa.stdout);
    this.kubeClientCert = pulumi.secret(parsedCert.stdout);
    this.kubeClientKey = pulumi.secret(parsedKey.stdout);

    this.registerOutputs({
      kubeconfig: this.kubeconfig,
      kubeHost: this.kubeHost,
      kubeCa: this.kubeCa,
      kubeClientCert: this.kubeClientCert,
      kubeClientKey: this.kubeClientKey,
    });
  }
}
