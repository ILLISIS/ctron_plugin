import React, { useContext, useMemo } from "react";
import { Table, Tag, Typography } from "antd";

import { ControlContext, PageHeader, PageLayout } from "@clusterio/web_ui";
import { WebPlugin } from "..";

type Row = {
	key: string;
	instanceId: number;
	instanceName: string;
	publisher: boolean;
	subscriber: boolean;
	serviceStationCount: number | null;
};

export default function InstanceRolesPage() {
	const control = useContext(ControlContext);
	const plugin = control.plugins.get("ctron_plugin") as WebPlugin;
	const statusByInstance = plugin.useServiceStationStatusByInstance();

	const rows = useMemo(() => {
		const instancesAny: any = control.instances;
		const instances: any[] = instancesAny
			? (typeof instancesAny.values === "function" ? Array.from(instancesAny.values()) : Array.from(instancesAny))
			: [];

		if (!instances.length) {
			return [...statusByInstance.values()]
				.map((status) => {
					const instanceId = status.instanceId;
					const subscriber = Boolean(status.isSubscriber);
					return {
						key: String(instanceId),
						instanceId,
						instanceName: "",
						publisher: !subscriber,
						subscriber,
						serviceStationCount: status.serviceStationCount,
					} satisfies Row;
				})
				.sort((a, b) => a.instanceId - b.instanceId);
		}

		return instances
			.map((inst: any) => {
				const instanceId = Number(inst.id);
				const name = inst.name || inst.config?.get?.("instance.name") || "";
				const status = statusByInstance.get(instanceId);
				const subscriber = Boolean(status?.isSubscriber);
				const count = status?.serviceStationCount;
				return {
					key: String(instanceId),
					instanceId,
					instanceName: name,
					publisher: !subscriber,
					subscriber,
					serviceStationCount: typeof count === "number" ? count : null,
				} satisfies Row;
			})
			.sort((a, b) => a.instanceId - b.instanceId);
	}, [control.instances, statusByInstance]);

	return (
		<PageLayout nav={[{ name: "Instances" }]}>
			<PageHeader title="Instance roles" />
			<div style={{ padding: 16 }}>
				<Typography.Paragraph type="secondary">
					All instances are publishers. An instance is a subscriber if it has at least one Constructron service station.
				</Typography.Paragraph>
				<Typography.Paragraph type="secondary">Status entries received: {statusByInstance.size}</Typography.Paragraph>
				<Table<Row>
					rowKey={(r: Row) => r.key}
					dataSource={rows}
					pagination={false}
					columns={[
						{
							title: "Instance",
							key: "instance",
							render: (_value: unknown, record: Row) =>
								record.instanceName
									? `${record.instanceName} (${record.instanceId})`
									: String(record.instanceId),
						},
						{
							title: "Publisher",
							key: "publisher",
							render: (_value: unknown, record: Row) =>
								record.publisher ? <Tag color="green">Yes</Tag> : <Tag>No</Tag>,
						},
						{
							title: "Subscriber",
							key: "subscriber",
							render: (_value: unknown, record: Row) =>
								record.subscriber ? <Tag color="blue">Yes</Tag> : <Tag>No</Tag>,
						},
						{
							title: "Service stations",
							dataIndex: "serviceStationCount",
							key: "serviceStationCount",
							render: (value: Row["serviceStationCount"]) => (value == null ? "—" : String(value)),
						},
					]}
				/>
			</div>
		</PageLayout>
	);
}
