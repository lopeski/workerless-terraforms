import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";

export interface PatchCoreDNSCommandArgs {
  readonly provider: kubernetes.Provider;
}

const ANTIMALWARE_FORWARD = "forward . 1.1.1.2 1.0.0.2";

function patchCorefile(original: string): string {
  const lines = original.split("\n");
  const patched = lines.map((line) => {
    const trimmed = line.trimStart();
    if (trimmed.startsWith("forward .")) {
      const indent = line.substring(0, line.length - trimmed.length);
      return `${indent}${ANTIMALWARE_FORWARD}`;
    }
    return line;
  });

  const hasForwardDirective = lines.some((l) => l.trimStart().startsWith("forward ."));
  if (!hasForwardDirective) {
    throw new Error(
      "CoreDNS Corefile does not contain a 'forward .' directive. " +
        "Cannot safely patch anti-malware resolvers.",
    );
  }

  return patched.join("\n");
}

export class PatchCoreDNSCommand extends pulumi.ComponentResource {
  constructor(
    name: string,
    args: PatchCoreDNSCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:PatchCoreDNSCommand", name, {}, opts);

    const existingCm = kubernetes.core.v1.ConfigMap.get(
      `${name}-coredns-existing`,
      pulumi.interpolate`kube-system/coredns`,
      { parent: this, provider: args.provider },
    );

    const patchedCorefile = existingCm.data.apply((d) => {
      const current = d?.["Corefile"] ?? "";
      return patchCorefile(current);
    });

    const patchedCm = new kubernetes.core.v1.ConfigMap(
      `${name}-coredns`,
      {
        metadata: {
          name: "coredns",
          namespace: "kube-system",
        },
        data: {
          Corefile: patchedCorefile,
        },
      },
      {
        parent: this,
        provider: args.provider,
        retainOnDelete: true,
        ignoreChanges: ["data.NodeHosts"],
      },
    );

    new kubernetes.apps.v1.Deployment(
      `${name}-coredns-restart`,
      {
        metadata: {
          name: "coredns",
          namespace: "kube-system",
          annotations: {
            "workerless.io/coredns-patched-at": patchedCm.metadata.resourceVersion.apply(
              (v) => v ?? "unknown",
            ),
          },
        },
        spec: {
          selector: { matchLabels: { "k8s-app": "kube-dns" } },
          template: {
            metadata: { labels: { "k8s-app": "kube-dns" } },
            spec: { containers: [] },
          },
        },
      },
      {
        parent: this,
        provider: args.provider,
        dependsOn: [patchedCm],
        ignoreChanges: ["spec", "metadata.annotations"],
        retainOnDelete: true,
      },
    );

    this.registerOutputs({});
  }
}
