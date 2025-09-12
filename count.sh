#!/bin/bash

output_file="rbac_audit.csv"
echo "Kind,Namespace,Name,Source" > $output_file

declare -A counts
declare -A results

# Collect data
for kind in clusterrole clusterrolebinding role rolebinding; do
  if [[ $kind == "role" || $kind == "rolebinding" ]]; then
    kubectl get $kind --all-namespaces -o json \
    | jq -r '.items[] | 
      {kind:"'"$kind"'", ns: .metadata.namespace, 
       name: .metadata.name, 
       manager: (.metadata.managedFields[].manager // empty), 
       labels: .metadata.labels, 
       annotations: .metadata.annotations} 
      | @json' \
    | while read -r line; do
        kind=$(echo $line | jq -r '.kind')
        ns=$(echo $line | jq -r '.ns')
        name=$(echo $line | jq -r '.name')
        manager=$(echo $line | jq -r '.manager' | tr '\n' ',' | sed 's/,$//')
        labels=$(echo $line | jq -r '.labels | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
        annotations=$(echo $line | jq -r '.annotations | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')

        if [[ $labels == *"helm"* || $annotations == *"helm"* || $manager == *"helm"* ]]; then
          source="Helm"
        elif [[ $labels == *"argocd"* || $annotations == *"argocd"* || $manager == *"argocd"* ]]; then
          source="ArgoCD"
        elif [[ $labels == *"flux"* || $annotations == *"flux"* || $manager == *"flux"* ]]; then
          source="Flux"
        elif [[ $labels == *"terraform"* || $annotations == *"terraform"* || $manager == *"Terraform"* ]]; then
          source="Terraform"
        elif [[ $manager == *"kubectl"* ]]; then
          source="kubectl (manual apply)"
        else
          source="Unknown"
        fi

        results["$kind|$ns|$name"]=$source
        counts["$source"]=$((counts["$source"]+1))
    done
  else
    kubectl get $kind -o json \
    | jq -r '.items[] | 
      {kind:"'"$kind"'", name: .metadata.name, 
       manager: (.metadata.managedFields[].manager // empty), 
       labels: .metadata.labels, 
       annotations: .metadata.annotations} 
      | @json' \
    | while read -r line; do
        kind=$(echo $line | jq -r '.kind')
        ns=""
        name=$(echo $line | jq -r '.name')
        manager=$(echo $line | jq -r '.manager' | tr '\n' ',' | sed 's/,$//')
        labels=$(echo $line | jq -r '.labels | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
        annotations=$(echo $line | jq -r '.annotations | to_entries[]? | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')

        if [[ $labels == *"helm"* || $annotations == *"helm"* || $manager == *"helm"* ]]; then
          source="Helm"
        elif [[ $labels == *"argocd"* || $annotations == *"argocd"* || $manager == *"argocd"* ]]; then
          source="ArgoCD"
        elif [[ $labels == *"flux"* || $annotations == *"flux"* || $manager == *"flux"* ]]; then
          source="Flux"
        elif [[ $labels == *"terraform"* || $annotations == *"terraform"* || $manager == *"Terraform"* ]]; then
          source="Terraform"
        elif [[ $manager == *"kubectl"* ]]; then
          source="kubectl (manual apply)"
        else
          source="Unknown"
        fi

        results["$kind|$ns|$name"]=$source
        counts["$source"]=$((counts["$source"]+1))
    done
  fi
done

# Function to print summary sorted by count
print_summary() {
  echo "=== Summary ($1) ==="
  for key in "${!counts[@]}"; do
    echo "$key,${counts[$key]}"
  done | sort -t',' -k2 -nr
}

# Summary before details
print_summary "before details"

# Write summary to CSV
echo "Source,Count" >> $output_file
for key in "${!counts[@]}"; do
  echo "$key,${counts[$key]}" >> $output_file
done

# Print details
for entry in "${!results[@]}"; do
  IFS="|" read -r kind ns name <<< "$entry"
  source="${results[$entry]}"
  if [[ -n "$ns" ]]; then
    echo "$kind $ns/$name --> $source"
    echo "$kind,$ns,$name,$source" >> $output_file
  else
    echo "$kind $name --> $source"
    echo "$kind,,$name,$source" >> $output_file
  fi
done

# Summary after details
print_summary "after details"

echo -e "\n📂 Results + summary saved to $output_file"