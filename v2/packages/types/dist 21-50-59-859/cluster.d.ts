export interface LocalClusterConfig {
    readonly clusterName: string;
    readonly apiPort: number;
    readonly servers: number;
    readonly agents: number;
}
export interface HetznerClusterConfig {
    readonly sshPublicKeyPath: string;
    readonly sshPrivateKeyPath: string;
    readonly k3sVersion: string;
    readonly serverType: string;
    readonly workerCount: number;
    readonly workerServerType: string;
    readonly location: string;
    readonly networkZone: string;
    readonly adminCidrs: readonly string[];
    readonly etcdSnapshotSchedule: string;
    readonly etcdSnapshotRetention: number;
}
//# sourceMappingURL=cluster.d.ts.map