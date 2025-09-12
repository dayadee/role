#!/bin/bash

output_file="rbac_audit.csv"
echo "Kind,Namespace,Name,RoleRefKind,RoleRefName,SubjectKind,SubjectName,Verb,Resource,Source" > $output_file

declare -A counts
declare -A results

# Helper: detect deployment source
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

# Expand rules into multiple rows (verb x resource)
expand_rules() {
  local rules="$1"
  if [[ -z "$rules" || "$rules" == "null" ]]; then
    echo "NoVerb,NoResource"
  else
    echo "$rules" | jq -c '.[]' | while read rule; do
      verbs=$(echo $rule | jq -r '.verbs[]?')
      resources=$(echo $rule | jq -r '.resources[]?')
      for v in $verbs; do
        for r in $resources; do
          echo "$v,$r"
        done
      done
    done
  fi
}

# Process ClusterRole / Role
process_roles() {
  local kind=$1
  if [[ $kind == "role" ]]; then
    kubectl get role --all-namespaces -o json | jq -r '.items[] | @base64' | while read item; do
      data=$(echo $item | base64 -d)
      ns=$(echo $data | jq -r '.metadata.namespace')
      name=$(echo $data | jq -r '.metadata.name')
      rules=$(echo $data | jq -c '.rules // []')
      manager=$(echo $data | jq -r '.metadata.managedFields[].manager? // empty' | tr '\n' ',' | sed 's/,$//')
      labels=$(echo $data | jq -r '.metadata.labels | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
      annotations=$(echo $data | jq -r '.metadata.annotations | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
      source=$(detect_source "$labels" "$annotations" "$manager")

      expand_rules "$rules" | while IFS=',' read verb resource; do
        results["$kind|$ns|$name|||||$verb|$resource"]=$source
        counts["$source"]=$((counts["$source"]+1))
      done
    done
  else
    kubectl get clusterrole -o json | jq -r '.items[] | @base64' | while read item; do
      data=$(echo $item | base64 -d)
      name=$(echo $data | jq -r '.metadata.name')
      rules=$(echo $data | jq -c '.rules // []')
      manager=$(echo $data | jq -r '.metadata.managedFields[].manager? // empty' | tr '\n' ',' | sed 's/,$//')
      labels=$(echo $data | jq -r '.metadata.labels | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
      annotations=$(echo $data | jq -r '.metadata.annotations | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
      source=$(detect_source "$labels" "$annotations" "$manager")

      expand_rules "$rules" | while IFS=',' read verb resource; do
        results["$kind||$name|||||$verb|$resource"]=$source
        counts["$source"]=$((counts["$source"]+1))
      done
    done
  fi
}

# Process RoleBinding / ClusterRoleBinding
process_bindings() {
  local kind=$1
  if [[ $kind == "rolebinding" ]]; then
    kubectl get rolebinding --all-namespaces -o json | jq -r '.items[] | @base64' | while read item; do
      data=$(echo $item | base64 -d)
      ns=$(echo $data | jq -r '.metadata.namespace')
      name=$(echo $data | jq -r '.metadata.name')
      roleRefKind=$(echo $data | jq -r '.roleRef.kind')
      roleRefName=$(echo $data | jq -r '.roleRef.name')
      subjects=$(echo $data | jq -c '.subjects // []')
      manager=$(echo $data | jq -r '.metadata.managedFields[].manager? // empty' | tr '\n' ',' | sed 's/,$//')
      labels=$(echo $data | jq -r '.metadata.labels | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
      annotations=$(echo $data | jq -r '.metadata.annotations | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
      source=$(detect_source "$labels" "$annotations" "$manager")

      echo $subjects | jq -c '.[]' | while read subj; do
        subjKind=$(echo $subj | jq -r '.kind')
        subjName=$(echo $subj | jq -r '.name')
        results["$kind|$ns|$name|$roleRefKind|$roleRefName|$subjKind|$subjName|NoVerb|NoResource"]=$source
        counts["$source"]=$((counts["$source"]+1))
      done
    done
  else
    kubectl get clusterrolebinding -o json | jq -r '.items[] | @base64' | while read item; do
      data=$(echo $item | base64 -d)
      name=$(echo $data | jq -r '.metadata.name')
      roleRefKind=$(echo $data | jq -r '.roleRef.kind')
      roleRefName=$(echo $data | jq -r '.roleRef.name')
      subjects=$(echo $data | jq -c '.subjects // []')
      manager=$(echo $data | jq -r '.metadata.managedFields[].manager? // empty' | tr '\n' ',' | sed 's/,$//')
      labels=$(echo $data | jq -r '.metadata.labels | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
      annotations=$(echo $data | jq -r '.metadata.annotations | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
      source=$(detect_source "$labels" "$annotations" "$manager")

      echo $subjects | jq -c '.[]' | while read subj; do
        subjKind=$(echo $subj | jq -r '.kind')
        subjName=$(echo $subj | jq -r '.name')
        results["$kind||$name|$roleRefKind|$roleRefName|$subjKind|$subjName|NoVerb|NoResource"]=$source
        counts["$source"]=$((counts["$source"]+1))
      done
    done
  fi
}

# Run all collectors
process_roles "role"
process_roles "clusterrole"
process_bindings "rolebinding"
process_bindings "clusterrolebinding"

# Print summary before
echo "=== Summary (before details) ==="
for key in "${!counts[@]}"; do
  echo "$key,${counts[$key]}"
done | sort -t',' -k2 -nr

# Print details + CSV
for entry in "${!results[@]}"; do
  IFS="|" read -r kind ns name roleRefKind roleRefName subjKind subjName verb resource <<< "$entry"
  source="${results[$entry]}"
  echo "$kind $ns/$name --> RoleRef=$roleRefKind/$roleRefName Subject=$subjKind/$subjName Verb=$verb Resource=$resource Source=$source"
  echo "$kind,$ns,$name,$roleRefKind,$roleRefName,$subjKind,$subjName,$verb,$resource,$source" >> $output_file
done

# Print summary after
echo "=== Summary (after details) ==="
for key in "${!counts[@]}"; do
  echo "$key,${counts[$key]}"
done | sort -t',' -k2 -nr

echo -e "\n📂 Results + summary saved to $output_file"