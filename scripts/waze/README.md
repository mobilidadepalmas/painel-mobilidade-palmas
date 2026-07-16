# Coleta automática do Waze Partner Hub (Palmas)

Este workflow (`.github/workflows/update-waze.yml`) roda a cada 5 minutos no GitHub Actions:

1. `Get-WazeFeed.ps1` busca o feed do Waze Partner Hub (URL vem dos **secrets** do repositório,
   nunca fica no código — ver abaixo) e acumula o histórico em `processed/*.csv`.
2. `Build-Dashboard.ps1` gera `dashboard.html` (na raiz do repositório) a partir desse histórico.
3. O `index.html` principal (card "Google Maps / Waze" em Aplicativos de Transporte) carrega
   `dashboard.html` num `<iframe>` — caminho relativo, funciona local e no GitHub Pages.

## Secrets necessários

Em **Settings → Secrets and variables → Actions** deste repositório:

- `WAZE_FEED_URL` — URL do feed do Partner Hub (alerts + jams). Funciona como token de acesso —
  nunca compartilhe ou commite em texto puro.
- `WAZE_TRAFFICVIEW_URL` — URL do endpoint "Traffic View" (estatísticas agregadas).

## Rodando localmente

```powershell
$env:WAZE_FEED_URL = "https://www.waze.com/row-partnerhub-api/partners/..."
$env:WAZE_TRAFFICVIEW_URL = "https://www.waze.com/row-partnerhub-api/feeds-tvt/..."
./Get-WazeFeed.ps1 -OutDir .
./Build-Dashboard.ps1 -OutDir ..\..
```

## Por que não usa 100% a mesma cópia local

A máquina local da SEMOB já tem uma Tarefa Agendada do Windows fazendo a mesma coisa (pasta
`PROGRAMAÇÃO IA\DADOS\waze_feed\`), rodando 24/7 nesta máquina específica. Este workflow no
GitHub Actions existe pra que o site publicado (GitHub Pages) também tenha dados ao vivo, mesmo
com a máquina da SEMOB desligada — os dois pipelines coletam o mesmo feed, cada um mantendo seu
próprio histórico independente.
