import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";

export interface WaitForNodesCommandArgs {
  readonly bootstrapPublicIp: pulumi.Input<string>;
  readonly sshPrivateKeyPath: string;
  readonly expectedNodeCount: number;
}

export class WaitForNodesCommand extends pulumi.ComponentResource {
  public readonly ready: pulumi.Output<string>;

  constructor(
    name: string,
    args: WaitForNodesCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:cluster:WaitForNodesCommand", name, {}, opts);

    const connection: command.types.input.remote.ConnectionArgs = {
      host: args.bootstrapPublicIp,
      user: "root",
      privateKey: pulumi.secret(
        require("fs").readFileSync(args.sshPrivateKeyPath, "utf8") as string,
      ),
    };

    const waitCmd = new command.remote.Command(
      `${name}-wait`,
      {
        connection,
        create: [
          `until [ $(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready) -ge ${args.expectedNodeCount} ]; do`,
          "  echo 'Waiting for nodes...'",
          "  sleep 10",
          "done",
          "echo 'All nodes ready'",
        ].join("\n"),
      },
      { parent: this },
    );

    this.ready = waitCmd.stdout;

    this.registerOutputs({ ready: this.ready });
  }
}
