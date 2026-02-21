import React, { useContext, useMemo } from "react";
import { Table, Typography } from "antd";

import { ControlContext, PageHeader, PageLayout } from "@clusterio/web_ui";
import { WebPlugin } from "..";

export default function JobsPage() {
	const control = useContext(ControlContext);
	const plugin = control.plugins.get("ctron_plugin") as WebPlugin;
	const jobs = plugin.useJobs();

	const rows = useMemo(() => {
		return jobs
			.filter(j => !j.isDeleted)
			.map(j => {
				const instance = control.instances?.get?.(j.lastInstanceId);
				const instanceName = instance?.name || instance?.config?.get?.("instance.name") || "";
				return {
					key: j.id,
					id: j.id,
					lastInstanceId: j.lastInstanceId,
					lastInstanceName: instanceName,
					jobType: j.jobType,
				};
			});
	}, [jobs, control.instances]);

	return (
		<PageLayout nav={[{ name: "Constructron jobs" }]}>
			<PageHeader title="Constructron jobs" />
			<div style={{ padding: 16 }}>
				<Typography.Paragraph type="secondary">
					Rows: {rows.length}
				</Typography.Paragraph>
				<Table
					rowKey={(r: any) => String(r.id)}
					dataSource={rows}
					pagination={{ pageSize: 50 }}
					columns={[
						{
							title: "Last instance",
							key: "lastInstance",
							render: (_value: unknown, record: any) =>
								record.lastInstanceName
									? `${record.lastInstanceName} (${record.lastInstanceId})`
									: String(record.lastInstanceId),
						},
						{ title: "Job type", dataIndex: "jobType", key: "jobType" },
					]}
				/>
			</div>
		</PageLayout>
	);
}
