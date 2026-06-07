# 🏥 XFarmaCare — Motor Autónomo de Retención y Rentabilidad

## Arquitectura del Proyecto

```
xfarmacare/
│
├── data/                          ← MODELO ESTRELLA (CSVs)
│   ├── dim_clientes.csv           → 8,000 clientes con perfil completo
│   ├── dim_productos.csv          → 180 productos farmacéuticos
│   ├── dim_sucursales.csv         → 25 sucursales en 32 provincias RD
│   ├── dim_fechas.csv             → Dimensión temporal 2023-2025
│   ├── fact_transacciones.csv     → 184,878 transacciones
│   ├── fact_interacciones_callcenter.csv → 5,864 interacciones con sentimiento
│   ├── fact_adherencia_terapeutica.csv   → 36,228 registros de adherencia
│   └── fact_campanas_retencion.csv      → 2,000 registros del experimento A/B
│
├── notebooks/                     ← JUPYTER NOTEBOOKS (.ipynb)
│   ├── 01_modelo_churn_entrenamiento.ipynb    → Feature engineering + entrenamiento
│   ├── 02_modelo_churn_scoring_diario.ipynb   → Pipeline diario (background job)
│   ├── 03_segmentacion_clustering_entrenamiento.ipynb → Clustering K-Means
│   ├── 04_segmentacion_clustering_scoring.ipynb       → Clasificar nuevos clientes
│   └── 05_motor_ofertas_automaticas.ipynb             → Reglas de negocio automáticas
│
├── r_scripts/                     ← SCRIPTS EN R
│   ├── 05_indice_priorizacion.R   → Matriz de valor ponderada + CLV
│   └── 06_uplift_modelado_causal.R → Causal Forest (grf) — EL DIFERENCIADOR
│
├── models/                        ← MODELOS EXPORTADOS
│   ├── modelo_churn_xfarmacare.pkl
│   ├── scaler_churn.pkl
│   ├── label_encoders_churn.pkl
│   ├── feature_cols_churn.pkl
│   ├── modelo_clustering_xfarmacare.pkl
│   ├── scaler_clustering.pkl
│   └── cluster_features.pkl
│
├── outputs/                       ← RESULTADOS (conectados por customer_id)
│   ├── output_churn_scores.csv           → Probabilidad de churn por cliente
│   ├── output_segmentos_clientes.csv     → Cluster y segmento conductual
│   ├── output_indice_priorizacion.csv    → Score de valor + CLV
│   ├── output_uplift_scores.csv          → Tipo de respuesta (persuadible/sleeping dog)
│   ├── output_motor_ofertas.csv          → Acción automática recomendada
│   └── dataset_analitico_clientes.csv    → Dataset unificado para análisis
│
└── README.md
```

## Modelo Estrella — Conexiones

```
                    dim_fechas
                        │
                        │ (fecha_compra)
                        │
dim_productos ──── fact_transacciones ──── dim_sucursales
                        │
                        │ (customer_id)
                        │
                   dim_clientes
                   /    |    \
                  /     |     \
   fact_adherencia  fact_callcenter  fact_campanas
                  \     |     /
                   \    |    /
              ┌─────────┴─────────┐
              │   OUTPUTS (CSV)   │
              ├───────────────────┤
              │ churn_scores      │
              │ segmentos         │──→ Todo unido
              │ indice_prioridad  │    por customer_id
              │ uplift_scores     │
              │ motor_ofertas     │
              └───────────────────┘
```

## Orden de Ejecución

1. **`01_modelo_churn_entrenamiento.ipynb`** — Entrenar y exportar modelo de churn
2. **`03_segmentacion_clustering_entrenamiento.ipynb`** — Entrenar clustering
3. **`05_indice_priorizacion.R`** — Calcular índice de valor (en R)
4. **`06_uplift_modelado_causal.R`** — Modelado causal (en R, requiere `grf`)
5. **`05_motor_ofertas_automaticas.ipynb`** — Generar acciones automáticas

### Jobs Recurrentes (diarios):
- **`02_modelo_churn_scoring_diario.ipynb`** — Actualizar probabilidades
- **`04_segmentacion_clustering_scoring.ipynb`** — Clasificar nuevos clientes

## Métricas del Modelo de Churn

| Métrica | Valor |
|---------|-------|
| AUC-ROC | 0.851 |
| Precision (Churner) | 0.75 |
| Recall (Churner) | 0.76 |
| F1-Score | 0.76 |

## Requisitos

### Python
```bash
pip install pandas numpy scikit-learn matplotlib seaborn joblib
```

### R
```r
install.packages(c("grf", "dplyr", "readr", "ggplot2", "scales"))
```

## Datos Sintéticos — Contexto RD

- **ARS:** Humano, Palic, Senasa, Universal, Reservas, Futuro, APS, MetaSalud
- **Provincias:** Las 32 provincias de República Dominicana
- **Condiciones crónicas:** Diabetes T2, Hipertensión, Asma, Dislipidemia, Hipotiroidismo, Artritis Reumatoide
- **Laboratorios:** INFACA, Sued, Rowe, GSK, Sanofi, Novo Nordisk, MSD, Pfizer, AstraZeneca
- **Moneda:** Pesos dominicanos (DOP)

## El Diferenciador: Uplift Modeling

El script `06_uplift_modelado_causal.R` implementa Causal Forests (Athey & Wager) para clasificar clientes en:

| Tipo | Descripción | Acción |
|------|-------------|--------|
| **Persuadible** | Solo se queda SI recibe la oferta | INVERTIR |
| **Sure Thing** | Se queda con o sin oferta | NO gastar |
| **Lost Cause** | Se va con o sin oferta | NO gastar |
| **Sleeping Dog** | Se va PORQUE recibe la oferta | NO tocar |

Basado en: Ascarza, E. (2018). "Retention Futility." *Journal of Marketing Research*.

---
*Motor de Retención XFarmaCare — Customer Intelligence*
