#!/usr/bin/env python3
"""Check rendered uploader ownership, release scopes, and notification routing."""
import json
from pathlib import Path
import re
import sys

import yaml


def matchers(selector):
    """Read the generated double-quoted PromQL label matchers."""
    return {m[1]: (m[2], json.loads(m[3])) for m in re.finditer(
        r'([a-zA-Z_][a-zA-Z0-9_]*)\s*(=~|!~|!=|=)\s*("(?:[^"\\]|\\.)*")', selector)}


def selectors(expression, metric):
    return [matchers(m[1]) for m in re.finditer(
        rf'\b{re.escape(metric)}\s*\{{([^}}]*)\}}', expression)]


problems = []
checked = 0
prefix = 'ais_edge:xnat_uploader_'
expected_alerts = {'XNATUploaderRestarted', 'XNATUploaderMemoryGrowing'}
expected_records = {prefix + name for name in (
    'pod', 'restarts_15m', 'memory_rss_bytes', 'memory_limit_bytes',
    'started_seconds', 'last_termination_reason')}
for path in sorted(Path(sys.argv[1]).glob('*.yaml')):
    docs = [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]
    rules = [r for d in docs if d.get('kind') == 'PrometheusRule'
             for group in d.get('spec', {}).get('groups', []) for r in group.get('rules', [])]
    if not rules:
        continue
    deployments = [d for d in docs if d.get('kind') == 'Deployment']
    uploaders = [d for d in deployments
                 if any(c.get('name') == 'upload' and c.get('command') == ['xnat-ingest', 'upload']
                        for c in d.get('spec', {}).get('template', {}).get('spec', {}).get('containers', []))]
    ours = [r for r in rules if r.get('alert', '').startswith('XNATUploader')]
    records = [r for r in rules if r.get('record', '').startswith(prefix)]
    if not uploaders:
        if ours or records:
            problems.append(f'{path.name}: uploader rules render without an uploader')
        continue
    if {r.get('alert') for r in ours} != expected_alerts or len(ours) != len(expected_alerts):
        problems.append(f'{path.name}: uploader alert inventory differs')
        continue
    if {r['record'] for r in records} != expected_records or len(records) != len(expected_records):
        problems.append(f'{path.name}: uploader recording inventory differs')
        continue
    checked += 1

    # Workload namespaces can differ from Helm's release namespace. The
    # rendered Prometheus CR retains the latter in both charts.
    releases = {d['metadata'].get('labels', {}).get('app.kubernetes.io/instance') for d in uploaders}
    prometheus = [d for d in docs if d.get('kind') == 'Prometheus'
                  and d.get('metadata', {}).get('labels', {}).get('app.kubernetes.io/instance') in releases]
    release_scopes = {f"{d['metadata']['namespace']}/{d['metadata']['labels']['app.kubernetes.io/instance']}"
                      for d in prometheus}
    if None in releases or len(releases) != 1 or len(release_scopes) != 1:
        problems.append(f'{path.name}: cannot identify one uploader Helm release from Prometheus')
        continue
    release_scope = next(iter(release_scopes))
    for rule in records:
        if rule.get('labels', {}).get('uploader_release') != release_scope:
            problems.append(f"{path.name}: {rule['record']} has the wrong uploader_release label")
    # Check every occurrence, including range selectors and dependent recording
    # rules. Unscoped references can read another release's or old recordings.
    for rule in rules:
        for ref in re.finditer(r'\b(ais_edge:xnat_uploader_[a-zA-Z0-9_:]+)\b(?:\s*\{([^}]*)\})?', rule.get('expr', '')):
            if matchers(ref[2] or '').get('uploader_release') != ('=', release_scope):
                name = rule.get('record', rule.get('alert'))
                problems.append(f'{path.name}: {name} reads {ref[1]} without its release scope')

    expression = next(r['expr'] for r in records if r['record'] == prefix + 'pod')
    pod_owners = selectors(expression, 'kube_pod_owner')
    replica_owners = selectors(expression, 'kube_replicaset_owner')
    if len(pod_owners) != 1 or len(replica_owners) != 1:
        problems.append(f'{path.name}: uploader pod mapping must select both owner metrics once')
        continue
    pod_owner, replica_owner = pod_owners[0], replica_owners[0]
    for selector, kind in ((pod_owner, 'ReplicaSet'), (replica_owner, 'Deployment')):
        if selector.get('owner_kind') != ('=', kind) or selector.get('owner_is_controller') != ('=', 'true'):
            problems.append(f'{path.name}: uploader mapping does not require controller ownership by {kind}')
        if selector.get('job') != ('=', 'kube-state-metrics'):
            problems.append(f'{path.name}: uploader ownership selector has the wrong scrape job')
        for deployment in uploaders:
            if selector.get('namespace') != ('=', deployment['metadata']['namespace']):
                problems.append(f"{path.name}: ownership selector misses namespace for {deployment['metadata']['name']}")
    deployment_matcher = replica_owner.get('owner_name')
    if not deployment_matcher or deployment_matcher[0] != '=~':
        problems.append(f'{path.name}: uploader mapping lacks a deployment-name regex')
        continue
    pattern = re.compile(deployment_matcher[1])
    uploader_names = {d['metadata']['name'] for d in uploaders}
    for name in uploader_names:
        if not pattern.fullmatch(name):
            problems.append(f'{path.name}: ownership selector misses uploader {name}')
    other_names = {d['metadata']['name'] for d in deployments} - uploader_names
    other_names.update(name + '-other' for name in uploader_names)
    other_names.update('other-' + name for name in uploader_names)
    other_names.add('other-upload')
    for name in other_names - uploader_names:
        if pattern.fullmatch(name):
            problems.append(f'{path.name}: ownership selector includes unrelated deployment {name}')

    configs = [yaml.safe_load(d['stringData']['alertmanager.yaml']) for d in docs
               if d.get('kind') == 'Secret' and 'alertmanager.yaml' in d.get('stringData', {})]
    if len(configs) != 1:
        problems.append(f'{path.name}: expected one Alertmanager configuration')
        continue
    am = configs[0]
    receivers = {r['name']: r for r in am['receivers']}
    routes = am['route']['routes']
    if (not routes or routes[0].get('matchers') != ['alertname =~ "Watchdog|InfoInhibitor"']
            or routes[0].get('receiver') != 'null-meta' or routes[0].get('continue', False)):
        problems.append(f'{path.name}: meta-alert null route must come first')
    for index, alert in enumerate(('XNATUploaderRestarted', 'XNATUploaderMemoryGrowing'), start=1):
        if len(routes) <= index or routes[index].get('matchers') != [f'alertname = "{alert}"']:
            problems.append(f'{path.name}: {alert} route must immediately follow the meta-alert route in uploader order')
    for alert in sorted(expected_alerts):
        matches = [r for r in routes if f'alertname = "{alert}"' in r.get('matchers', [])]
        if len(matches) != 1:
            problems.append(f'{path.name}: {alert} lacks one explicit route')
            continue
        route = matches[0]
        if not {'cluster', 'namespace', 'pod', 'container'}.issubset(route.get('group_by', [])):
            problems.append(f'{path.name}: {alert} groups unrelated uploaders')
        if route.get('repeat_interval') != '24h':
            problems.append(f'{path.name}: {alert} lost its daily repeat limit')
        catchall = next((i for i, r in enumerate(routes) if 'severity = "warning"' in r.get('matchers', [])), len(routes))
        if routes.index(route) >= catchall:
            problems.append(f'{path.name}: {alert} route is shadowed by warning routing')
        emails = receivers.get(route.get('receiver'), {}).get('email_configs', [])
        if not emails:
            problems.append(f'{path.name}: {alert} route cannot deliver email')
        elif alert == 'XNATUploaderRestarted' and any(e.get('send_resolved', True) for e in emails):
            problems.append(f'{path.name}: restart event route cannot deliver firing-only email')
if not checked:
    problems.append('no rendered uploader alert was checked')
if problems:
    raise SystemExit('\n'.join(problems))
print(f'{checked} renders: uploader ownership, release scopes, and notification routes match their workloads')
