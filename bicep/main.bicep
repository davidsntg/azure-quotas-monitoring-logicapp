// Location
param Location string = 'West Europe'

// Log Analytic Workspace
param LawName string = 'quotasmonitoring-law'
param LawSku string = 'pergb2018'

// Logic Appp
@description('The name of the logic app to create.')
param logicAppName string = 'quotasmonitoring-logicapp'

param frequency string = 'Day'
param interval string = '1'

resource Lag 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: LawName
  location: Location
  properties:{
    sku:{
      name: LawSku
    }
  }
}

resource integrationAccount 'Microsoft.Logic/integrationAccounts@2016-06-01' = {
  name: 'quotasmonitoring-integrationaccount'
  location: Location
  sku: {
    name: 'Free'
  }
  properties:{
    state: 'Enabled'
  }
}

resource integrationAccountMap 'Microsoft.Logic/integrationAccounts/maps@2016-06-01' = {
  name: 'quotasmonitoring-integrationaccount/JsonToJson3'
  properties:{
    mapType: 'Liquid'
    content: '''[
{% for quota in content.value %}{
    "quotaCategory": "QUOTACATEGORYTOREPLACE",
    "subscriptionId": "SUBSCRIPTIONTOREPLACE",
    "region": "REGIONTOREPLACE",
    "quotaName": "{{quota.name.value}}",
    "currentValue": {{quota.currentValue}},
    "limit": {{quota.limit}}
}{%- if forloop.Last == true -%}{%- else -%},{%- endif -%}{% endfor%}
]'''
    contentType: 'text/plain'
  }
  dependsOn:[
    integrationAccount
  ]
}

resource lawApiConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'azureloganalyticsdatacollector'
  location: Location
  properties:{
    api: {
      id: '${subscription().id}/providers/Microsoft.Web/locations/${Location}/managedApis/azureloganalyticsdatacollector'
      name: 'azureloganalyticsdatacollector'
    }
    parameterValues:{
      username: Lag.properties.customerId
      password: listKeys(Lag.id, '2015-03-20').primarySharedKey
    }
  }
  dependsOn:[
    integrationAccountMap
  ]
}

var type = 'recurrence'
var workflowSchema = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'

resource stg 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: Location
  tags: {
    displayName: logicAppName
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    integrationAccount:{
      id: integrationAccount.id
    }
    parameters:{
      '$connections': {
        value: {
          azureloganalyticsdatacollector: {
            connectionId: resourceId('Microsoft.Web/connections', 'azureloganalyticsdatacollector')
            connectionName: 'azureloganalyticsdatacollector'
            id: '${subscription().id}/providers/Microsoft.Web/locations/${Location}/managedApis/azureloganalyticsdatacollector'
          }
        }
      }
    }
    definition: {
      '$schema': workflowSchema
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          type: 'Object'
          defaultValue: {}
        }
      }
      triggers: {
        recurrence: {
          type: type
          recurrence: {
            frequency: frequency
            interval: interval
          }
        }
      }
      actions: {
        'Initialize_variable_-_location':{
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'location'
                type: 'string'
                value: 'null'
              }
            ]
          }
        }
        'API_Call_-_Get_All_Subscription_Ids':{
          runAfter: {
            'Initialize_variable_-_location': [
              'Succeeded'
            ]
          }
          type: 'Http'
          inputs: {
            authentication: {
              type: 'ManagedServiceIdentity'
            }
            method: 'POST'
            uri: 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources'
            headers: {
              'Content-Type': 'application/json'
            }
            queries: {
              'api-version': '2021-03-01'
            }
            body: {
              query: 'Resources | project subscriptionId | distinct subscriptionId'
            }
          }
        }
        'For_each_-_subscriptionIds':{
          runAfter: {
            'API_Call_-_Get_All_Subscription_Ids': [
              'Succeeded'
            ]
          }
          type: 'Foreach'
          foreach: '@body(\'API_Call_-_Get_All_Subscription_Ids\')?[\'data\']'
          actions: {
            'API_call_-_Get_distinct_resources_locations_in_the_subscription': {
              runAfter: {}
              type: 'Http'
              inputs: {
                authentication: {
                  type: 'ManagedServiceIdentity'
                }
                method: 'POST'
                uri: 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources'
                headers: {
                  'Content-Type': 'application/json'
                }
                queries: {
                  'api-version': '2021-03-01'
                }
                body: {
                  query: 'Resources | where subscriptionId == "@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}" | project location | distinct location'
                }
              }
            }
            'For_each_-_locations_in_subscriptionId': {
              runAfter: {
                'API_call_-_Get_distinct_resources_locations_in_the_subscription': [
                  'Succeeded'
                ]
              }
              type: 'Foreach'
              foreach: '@body(\'API_call_-_Get_distinct_resources_locations_in_the_subscription\')?[\'data\']'
              actions: {
                'Set_variable_-_location': {
                  runAfter: {}
                  type: 'SetVariable'
                  inputs: {
                    name: 'location'
                    value: '@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}'
                  }
                }
                'API_Call_-_Get_Microsoft.Compute_Quota_for_subscriptionId__region': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.Compute/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2022-08-01'
                    }
                  }
                }
                Condition_8: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.Compute_Quota_for_subscriptionId__region': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.Compute_Quota_for_subscriptionId__region\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.Compute': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.Compute_Quota_for_subscriptionId__region\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.Compute_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.Compute': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.Compute\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.Compute\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }
                    }
                  }
                }
                'API_Call_-_Get_Microsoft.HDInsight_Quota_for_subscriptionId_region': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.HDInsight/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2018-06-01-preview'
                    }
                  }
                }
                Condition_7: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.HDInsight_Quota_for_subscriptionId_region': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.HDInsight_Quota_for_subscriptionId_region\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.HDInsight': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.HDInsight_Quota_for_subscriptionId_region\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.HDInsight_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.HDInsight': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.HDInsight\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.HDInsight\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }
                    }
                  }
                }
                'API_Call_-_Get_Microsoft.LabServices_Quota_for_subscriptionId_region': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.LabServices/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2022-08-01'
                    }
                  }
                }
                Condition_6: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.LabServices_Quota_for_subscriptionId_region': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.LabServices_Quota_for_subscriptionId_region\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.LabServices': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.LabServices_Quota_for_subscriptionId_region\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.LabServices_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.LabServices': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.LabServices\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.LabServices\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }
                    }
                  }
                }
                'API_Call_-_Get_Microsoft.MachineLearningServices_Quota_for_subscriptionId_region': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.MachineLearningServices/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2021-10-01'
                    }
                  }
                }
                Condition_5: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.MachineLearningServices_Quota_for_subscriptionId_region': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.MachineLearningServices_Quota_for_subscriptionId_region\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.MachineLearningServices': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.MachineLearningServices_Quota_for_subscriptionId_region\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.MachineLearningServices_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.MachineLearningServices': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.MachineLearningServices\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.MachineLearningServices\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }
                    }
                  }
                }
                'API_Call_-_Get_Microsoft.Network_Quota_for_subscriptionId_region_': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.Network/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2020-07-01'
                    }
                  }
                }
                Condition_4: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.Network_Quota_for_subscriptionId_region_': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.Network_Quota_for_subscriptionId_region_\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.Network': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.Network_Quota_for_subscriptionId_region_\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.Network_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.Network': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.Network\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.Network\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }
                    }
                  }
                }
                'API_Call_-_Get_Microsoft.Purview_Quota_for_subscriptionId_region': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.Purview/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2021-12-01'
                    }
                  }
                }
                Condition_9: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.Purview_Quota_for_subscriptionId_region': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.Purview_Quota_for_subscriptionId_region\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.Purview': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.Purview_Quota_for_subscriptionId_region\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.Purview_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.Purview': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.Purview\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.Purview\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }
                    }
                  }
                }
                'API_Call_-_Get_Microsoft.StorageCache_Quota_for_subscriptionId_region': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.StorageCache/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2022-01-01'
                    }
                  }
                }
                Condition_3: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.StorageCache_Quota_for_subscriptionId_region': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.StorageCache_Quota_for_subscriptionId_region\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.StorageCache': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.StorageCache_Quota_for_subscriptionId_region\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.StorageCache_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.StorageCache': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.StorageCache\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.StorageCache\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }
                    }
                  }
                }
                'API_Call_-_Get_Microsoft.Storage_Quota_for_subscriptionId_region': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.Storage/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2018-02-01'
                    }
                  }
                }
                Condition: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.Storage_Quota_for_subscriptionId_region': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.Storage_Quota_for_subscriptionId_region\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.Storage': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.Storage_Quota_for_subscriptionId_region\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.Storage_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.Storage': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.Storage\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.Storage\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }

                    }
                  }
                }
                'API_Call_-_Get_Microsoft.VMwareCloudSimple_Quota_for_subscriptionId_region': {
                  runAfter: {
                    'Set_variable_-_location': [
                      'Succeeded'
                    ]
                  }
                  type: 'Http'
                  inputs: {
                    authentication: {
                      type: 'ManagedServiceIdentity'
                    }
                    method: 'GET'
                    uri: 'https://management.azure.com/subscriptions/@{items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']}/providers/Microsoft.VMwareCloudSimple/locations/@{items(\'For_each_-_locations_in_subscriptionId\')[\'location\']}/usages'
                    queries: {
                      'api-version': '2019-04-01'
                    }
                  }
                }
                Condition_2: {
                  runAfter: {
                    'API_Call_-_Get_Microsoft.VMwareCloudSimple_Quota_for_subscriptionId_region': [
                      'Succeeded'
                      'Failed'
                      'Skipped'
                      'TimedOut'
                    ]
                  }
                  type: 'If'
                  expression: {
                    and: [
                      {
                        equals: [
                          '@outputs(\'API_Call_-_Get_Microsoft.VMwareCloudSimple_Quota_for_subscriptionId_region\')[\'statusCode\']'
                          200
                        ]
                      }
                    ]
                  }
                  actions: {
                    'Format_Json_-_Microsoft.VMwareCloudSimple': {
                      runAfter: {}
                      type: 'Liquid'
                      kind: 'JsonToJson'
                      inputs: {
                        content: '@body(\'API_Call_-_Get_Microsoft.VMwareCloudSimple_Quota_for_subscriptionId_region\')'
                        integrationAccount: {
                          map: {
                            name: 'JsonToJson3'
                          }
                        }
                      }
                    }
                    'Send_Data_-_Microsoft.VMwareCloudSimple_Quotas': {
                      runAfter: {
                        'Format_Json_-_Microsoft.VMwareCloudSimple': [
                          'Succeeded'
                        ]
                      }
                      type: 'ApiConnection'
                      inputs: {
                        body: '@{json(replace(replace(replace(string(body(\'Format_Json_-_Microsoft.VMwareCloudSimple\')),\'REGIONTOREPLACE\', items(\'For_each_-_locations_in_subscriptionId\')[\'location\']), \'QUOTACATEGORYTOREPLACE\', \'Microsoft.VMwareCloudSimple\'), \'SUBSCRIPTIONTOREPLACE\', items(\'For_each_-_subscriptionIds\')[\'subscriptionId\']))}'
                        headers: {
                          'Log-Type': 'SubscriptionQuota'
                        }
                        host: {
                          connection: {
                            name: '@parameters(\'$connections\')[\'azureloganalyticsdatacollector\'][\'connectionId\']'
                          }
                        }
                        method: 'post'
                        path: 'api/logs'
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  dependsOn:[
    lawApiConnection
  ]
}
