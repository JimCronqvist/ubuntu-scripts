kubectl get pods --all-namespaces -o jsonpath='
{range .items[*]}
  {range .spec.initContainers[*]}
    {.image}{"\t"}{.name}{" (init)"}{"\t"}{.metadata.name}{"\t"}{.metadata.namespace}{"\n"}
  {end}
  {range .spec.containers[*]}
    {.image}{"\t"}{.name}{"\t"}{.metadata.name}{"\t"}{.metadata.namespace}{"\n"}
  {end}
{end}' | awk '
BEGIN { OFS="\t" }
{
  image=$1
  split(image, parts, "/")
  if (length(parts)==1 || (length(parts)==2 && parts[1] !~ /[.:]/)) {
    image = "docker.io/" image
  }
  print image, $2, $3, $4
}' | sort | column -t
