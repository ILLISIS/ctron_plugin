import React, { useContext, useMemo } from "react";
import { Table, Typography } from "antd";

import { ControlContext, PageHeader, PageLayout } from "@clusterio/web_ui";
import { WebPlugin } from "..";

export default function RoboportCountsPage() {
	const control = useContext(ControlContext);
	const plugin = control.plugins.get("ctron_plugin") as WebPlugin;
	const countsByInstance = plugin.useCountsByInstance();

	const rows = useMemo(() => {
		return [...countsByInstance.entries()]
			.map(([instanceId, count]) => {
				const instance = control.instances?.get?.(instanceId);
				const name = instance?.name || instance?.config?.get?.("instance.name");
				return {
					key: instanceId,
					instanceId,
					instanceName: name ?? "",
					count,
				};
			})
			.sort((a, b) => a.instanceId - b.instanceId);
	}, [countsByInstance, control.instances]);

	return (
		<PageLayout nav={[{ name: "Roboport counts" }]}>
			<PageHeader title="Player-built roboports" />
			<div style={{ padding: 16 }}>
				<Typography.Paragraph type="secondary">
					Rows: {rows.length}
				</Typography.Paragraph>
				<Table
					rowKey={(r: any) => String(r.instanceId)}
					dataSource={rows}
					pagination={false}
					columns={[
						{
							title: "Instance",
							key: "instance",
							render: (_value: unknown, record: any) =>
								record.instanceName
									? `${record.instanceName} (${record.instanceId})`
									: String(record.instanceId),
						},
						{ title: "Roboports built", dataIndex: "count", key: "count" },
					]}
				/>
			</div>
		</PageLayout>
	);
}
