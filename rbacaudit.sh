#!/bin/bash

output_file="rbac_combined_safe.csv"
echo "Kind,Namespace,Name,RoleRefKind,RoleRefName,SubjectKind,SubjectName,Verb,Resource,Source" > $output_file

declare -A counts

# Detect deployment source
detect_source() {
  local labels="$1"
  local annotations="$2"
  local manager="$3"
  if [[ $labels == *"helm"* || $annotations == *"helm"* || $manager == *"helm"* ]]; then
    echo "Helm"
  elif [[ $labels == *"argocd"* || $annotations == *"argocd"* || $manager == *"argocd"* ]]; then
    echo "ArgoCD"
  elif [[ $labels == *"flux"* || $annotations == *"flux"* || $manager == *"flux"* ]]; then
    echo "Flux"
  elif [[ $labels == *"terraform"* || $annotations == *"terraform"* || $manager == *"Terraform"* ]]; then
    echo "Terraform"
  elif [[ $manager == *"kubectl"* || $annotations == *"kubectl.kubernetes.io/last-applied-configuration"* ]]; then
    echo "kubectl (manual apply)"
  else
    echo "Unknown"
  fi
}

# Expand rules into verb + resource
expand_rules() {
  local rules="$1"
  [[ -z "$rules" || "$rules" == "null" || "$rules" == "[]" ]] && return
  echo "$rules" | jq -c '.[]' | while read rule; do
    verbs=$(echo $rule | jq -r '.verbs // [] | .[]')
    resources=$(echo $rule | jq -r '.resources // [] | .[]')
    for v in $verbs; do
      for r in $resources; do
        echo "$v,$r"
      done
    done
  done
}

# Process Roles / ClusterRoles
process_roles() {
  local kind=$1
  local items
  [[ $kind == "role" ]] && items=$(kubectl get role --all-namespaces -o json) || items=$(kubectl get clusterrole -o json)
  [[ $(echo "$items" | jq '.items | length') -eq 0 ]] && return

  echo "$items" | jq -r '.items[] | @base64' | while read item; do
    data=$(echo $item | base64 -d)
    ns=$(echo $data | jq -r '.metadata.namespace // ""')
    name=$(echo $data | jq -r '.metadata.name // ""')
    rules=$(echo $data | jq -c '.rules // []')
    [[ "$rules" == "[]" ]] && continue
    # Safe managedFields extraction
    manager=$(echo "$data" | jq -r 'if .metadata.managedFields? then [.metadata.managedFields[].manager] | join(",") else "" end')
    labels=$(echo $data | jq -r '.metadata.labels // {} | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
    annotations=$(echo $data | jq -r '.metadata.annotations // {} | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
    source=$(detect_source "$labels" "$annotations" "$manager")

    expand_rules "$rules" | while IFS=',' read verb resource; do
      echo "$kind,$ns,$name,,,,,$verb,$resource,$source" >> $output_file
      counts["$source"]=$((counts["$source"]+1))
    done
  done
}

# Process RoleBindings / ClusterRoleBindings
process_bindings() {
  local kind=$1
  local items
  [[ $kind == "rolebinding" ]] && items=$(kubectl get rolebinding --all-namespaces -o json) || items=$(kubectl get clusterrolebinding -o json)
  [[ $(echo "$items" | jq '.items | length') -eq 0 ]] && return

  echo "$items" | jq -r '.items[] | @base64' | while read item; do
    data=$(echo $item | base64 -d)
    ns=$(echo $data | jq -r '.metadata.namespace // ""')
    name=$(echo $data | jq -r '.metadata.name // ""')
    roleRefKind=$(echo $data | jq -r '.roleRef.kind // ""')
    roleRefName=$(echo $data | jq -r '.roleRef.name // ""')
    subjects=$(echo $data | jq -c '.subjects // []')
    [[ "$subjects" == "[]" ]] && return
    manager=$(echo "$data" | jq -r 'if .metadata.managedFields? then [.metadata.managedFields[].manager] | join(",") else "" end')
    labels=$(echo $data | jq -r '.metadata.labels // {} | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
    annotations=$(echo $data | jq -r '.metadata.annotations // {} | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
    source=$(detect_source "$labels" "$annotations" "$manager")

    echo "$subjects" | jq -c '.[]' | while read subj; do
      subjKind=$(echo $subj | jq -r '.kind // "NoSubject"')
      subjName=$(echo $subj | jq -r '.name // ""')
      echo "$kind,$ns,$name,$roleRefKind,$roleRefName,$subjKind,$subjName,,,,$source" >> $output_file
      counts["$source"]=$((counts["$source"]+1))
    done
  done
}

# Run all
process_roles "role"
process_roles "clusterrole"
process_bindings "rolebinding"
process_bindings "clusterrolebinding"

# Summary
echo "=== Summary ==="
for key in "${!counts[@]}"; do
  echo "$key,${counts[$key]}"
done | sort -t',' -k2 -nr

echo -e "\n📂 Fully safe combined RBAC audit CSV: $output_file"