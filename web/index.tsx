import React, { useCallback, useMemo, useSyncExternalStore } from "react";

import { BaseWebPlugin } from "@clusterio/web_ui";
import * as lib from "@clusterio/lib";

import * as messages from "../messages";
import InstanceRolesPage from "./pages/InstanceRolesPage";

export class WebPlugin extends BaseWebPlugin {
	serviceStationSubscriber!: lib.MapSubscriber<messages.InstanceServiceStationStatusStream>;

	async init() {
		this.serviceStationSubscriber = new lib.MapSubscriber(
			messages.InstanceServiceStationStatusStream, this.control,
		);
		this.pages = [
			{
				path: "/ctron_plugin",
				sidebarName: "Constructron",
				permission: "ctron_plugin.jobs.read",
				content: <InstanceRolesPage />,
			},
		];
	}

	/** Each instance's service station status, by instance id; subscribed while a page uses it. */
	useServiceStationStatusByInstance() {
		const subscribe = useCallback((cb: () => void) => this.serviceStationSubscriber.subscribe(() => cb()), []);
		const [values] = useSyncExternalStore(subscribe, () => this.serviceStationSubscriber.getSnapshot());
		return useMemo(() => {
			const map = new Map<number, Readonly<messages.InstanceServiceStationStatus>>();
			for (const v of values.values()) {
				map.set(v.instanceId, v);
			}
			return map;
		}, [values]);
	}
}
