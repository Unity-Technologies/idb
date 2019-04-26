#!/usr/bin/env python3
# Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.


from typing import Set

from idb.common.companion import CompanionClient
from idb.grpc.idb_pb2 import ApproveRequest


MAP = {
    "photos": ApproveRequest.PHOTOS,
    "camera": ApproveRequest.CAMERA,
    "contacts": ApproveRequest.CONTACTS,
}


async def client(
    client: CompanionClient, bundle_id: str, permissions: Set[str]
) -> None:
    print(f"Sending {[MAP[permission] for permission in permissions]}")
    await client.stub.approve(
        ApproveRequest(
            bundle_id=bundle_id,
            permissions=[MAP[permission] for permission in permissions],
        )
    )