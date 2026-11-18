/*
 * node_dns.h — captive-portal DNS of the Soft AP.
 * SPDX-License-Identifier: MIT
 */
#ifndef NODE_DNS_H
#define NODE_DNS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool nodeDnsStart(uint32_t ip_network_order);   /* answers every A query with this IP */
void nodeDnsStop(void);

#ifdef __cplusplus
}
#endif

#endif
