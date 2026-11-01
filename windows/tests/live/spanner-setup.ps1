# Creates the instance and database the Spanner live test names, on the emulator compose.yaml starts. The emulator
# keeps nothing across restarts, so run this after every start.
param(
    [string]$Rest = 'http://localhost:9020',
    [string]$Project = 'tablepro',
    [string]$Instance = 'test',
    [string]$Database = 'tablepro'
)

$ErrorActionPreference = 'Stop'
$instanceBody = @{ instanceId = $Instance; instance = @{ config = "projects/$Project/instanceConfigs/emulator-config"; displayName = $Instance; nodeCount = 1 } } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "$Rest/v1/projects/$Project/instances" -Body $instanceBody -ContentType 'application/json' | Out-Null
$databaseBody = @{ createStatement = "CREATE DATABASE ``$Database``" } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "$Rest/v1/projects/$Project/instances/$Instance/databases" -Body $databaseBody -ContentType 'application/json' | Out-Null
"projects/$Project/instances/$Instance/databases/$Database"
