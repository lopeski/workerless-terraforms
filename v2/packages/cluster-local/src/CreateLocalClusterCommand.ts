import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";
import type { LocalClusterConfig } from "@workerless/types";

export interface CreateLocalClusterCommandArgs {
  readonly config: LocalClusterConfig;
}

export class CreateLocalClusterCommand extends pulumi.ComponentResource {
  public readonly clusterName: pulumi.Output<string>;

  constructor(
    name: string,
    args: CreateLocalClusterCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:cluster:CreateLocalClusterCommand", name, {}, opts);

    const { config } = args;

    const cluster = new command.local.Command(
      `${name}-k3d`,
      {
        create: [
          "k3d cluster create",
          config.clusterName,
          "--api-port", String(config.apiPort),
          "--servers", String(config.servers),
          "--agents", String(config.agents),
          "--wait",
        ].join(" "),
        delete: `k3d cluster delete ${config.clusterName}`,
      },
      { parent: this },
    );

    this.clusterName = cluster.id.apply(() => config.clusterName);

    this.registerOutputs({ clusterName: this.clusterName });
  }
}
