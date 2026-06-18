window.BENCHMARK_DATA = {
  "lastUpdate": 1781812404898,
  "repoUrl": "https://github.com/NigelTatem/jsip-exchange",
  "entries": {
    "Order book benchmark": [
      {
        "commit": {
          "author": {
            "email": "ubuntu@ip-172-31-29-102.us-east-2.compute.internal",
            "name": "nigeltatem2@gmail.com"
          },
          "committer": {
            "email": "ubuntu@ip-172-31-29-102.us-east-2.compute.internal",
            "name": "nigeltatem2@gmail.com"
          },
          "distinct": true,
          "id": "a4756780abcae2c349077198831cdbf629b987a3",
          "message": "exercise2",
          "timestamp": "2026-06-18T19:48:56Z",
          "tree_id": "e3b7a66d3f42fad8ec077aa09fd0532fa95a7a1d",
          "url": "https://github.com/NigelTatem/jsip-exchange/commit/a4756780abcae2c349077198831cdbf629b987a3"
        },
        "date": 1781812404676,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "find_match (n=10)",
            "value": 247.34764042132787,
            "unit": "ns"
          },
          {
            "name": "find_match (n=50)",
            "value": 1216.1812784095735,
            "unit": "ns"
          },
          {
            "name": "find_match (n=100)",
            "value": 2416.8219465320844,
            "unit": "ns"
          },
          {
            "name": "find_match (n=500)",
            "value": 11714.7970702684,
            "unit": "ns"
          },
          {
            "name": "find_match_miss (n=10)",
            "value": 85.72776774616109,
            "unit": "ns"
          },
          {
            "name": "find_match_miss (n=50)",
            "value": 379.24162475511065,
            "unit": "ns"
          },
          {
            "name": "find_match_miss (n=100)",
            "value": 733.8551712453507,
            "unit": "ns"
          },
          {
            "name": "find_match_miss (n=500)",
            "value": 3582.988114075637,
            "unit": "ns"
          },
          {
            "name": "best_bid_offer (n=10)",
            "value": 193.02122970867404,
            "unit": "ns"
          },
          {
            "name": "best_bid_offer (n=50)",
            "value": 1038.949952458795,
            "unit": "ns"
          },
          {
            "name": "best_bid_offer (n=100)",
            "value": 1986.1083459798278,
            "unit": "ns"
          },
          {
            "name": "best_bid_offer (n=500)",
            "value": 9669.709906353703,
            "unit": "ns"
          },
          {
            "name": "add+remove (n=100)",
            "value": 1884.2390356590802,
            "unit": "ns"
          },
          {
            "name": "submit_ioc_cross (n=10)",
            "value": 1497.6808874415997,
            "unit": "ns"
          },
          {
            "name": "submit_ioc_cross (n=50)",
            "value": 6770.732111811206,
            "unit": "ns"
          },
          {
            "name": "submit_ioc_cross (n=100)",
            "value": 12560.562146866185,
            "unit": "ns"
          },
          {
            "name": "submit_ioc_cross (n=500)",
            "value": 60287.796691208336,
            "unit": "ns"
          },
          {
            "name": "submit_ioc_miss (n=10)",
            "value": 570.8908583035565,
            "unit": "ns"
          },
          {
            "name": "submit_ioc_miss (n=50)",
            "value": 2715.922005898448,
            "unit": "ns"
          },
          {
            "name": "submit_ioc_miss (n=100)",
            "value": 5118.516546263431,
            "unit": "ns"
          },
          {
            "name": "submit_ioc_miss (n=500)",
            "value": 23895.933189989213,
            "unit": "ns"
          },
          {
            "name": "submit_sweep_10_levels",
            "value": 5791.838957134875,
            "unit": "ns"
          },
          {
            "name": "submit_sweep_50_levels",
            "value": 110738.92703744765,
            "unit": "ns"
          },
          {
            "name": "submit_sweep_100_levels",
            "value": 424473.69438896904,
            "unit": "ns"
          },
          {
            "name": "find_match_alloc (n=100)",
            "value": 2424.8269346597194,
            "unit": "ns"
          }
        ]
      }
    ]
  }
}