# Kafka + Flink CEP + .NET Core — Arquitetura de Consumo Particionado

> Conversa técnica cobrindo desde consumidores SQS/Kafka particionados em .NET até arquitetura completa com Flink CEP, Valkey, gRPC e SignalR.

---

## Sumário

1. [Consumidor SQS com Particionamento](#consumidor-sqs-com-particionamento)
2. [SQS FIFO vs Kafka](#sqs-fifo-vs-kafka)
3. [Consumidor Kafka Particionado em .NET](#consumidor-kafka-particionado-em-net)
4. [Flink Sink com AgenciaId como Chave](#flink-sink-com-agenciaid-como-chave)
5. [Agrupando Matches Correlacionados](#agrupando-matches-correlacionados)
6. [Usando Valkey para Persistir Grupos](#usando-valkey-para-persistir-grupos)
7. [Arquitetura Completa: Worker gRPC + SignalR + REST](#arquitetura-completa)
8. [CorrelationId](#correlationid)
9. [Flink CEP — Tipos de Regras e Correlações](#flink-cep--tipos-de-regras-e-correlações)

---

## Consumidor SQS com Particionamento

SQS não tem partições nativas como Kafka. O equivalente são as **Message Group IDs** das filas FIFO. A abordagem de uma Task por "partição" é válida com `Channel<T>`:

```
 ┌──────────────────────────────────────────────┐
 │              Polling Loop (1 Task)           │
 │   ReceiveMessageAsync → batch de mensagens   │
 └──────────────────┬───────────────────────────┘
                    │ fan-out por MessageGroupId
       ┌────────────┼────────────┐
       ▼            ▼            ▼
  Channel[A]   Channel[B]   Channel[C]
       │            │            │
  Task[A]       Task[B]       Task[C]
 (sequencial)  (sequencial)  (sequencial)
```

### Pontos de Atenção no SQS

- **Visibility Timeout**: estender antes de expirar se o processamento demorar
- **Crescimento ilimitado de partições**: limitar com `SemaphoreSlim`
- **Cleanup de partições ociosas**: fechar canais inativos com timer
- **SQS Standard vs FIFO**: sem ordering, `Parallel.ForEachAsync` pode ser mais simples

---

## SQS FIFO vs Kafka

| Característica | SQS FIFO | Kafka |
|---|---|---|
| Ordenação | Por `MessageGroupId` | Por partição |
| Throughput máximo | ~3.000 msg/s por fila | Praticamente ilimitado |
| Replay de mensagens | ❌ | ✅ Nativo |
| Consumer groups | ❌ | ✅ Nativo |
| Deduplicação | ✅ Nativa (5 min window) | ❌ Precisa implementar |
| Integração com Flink | Indireta | **Nativa** |

### Quando SQS FIFO faz sentido
- Volume baixo/médio (< 3k msg/s)
- Já está 100% na AWS e quer simplicidade operacional
- Precisa de deduplicação automática
- Não precisa de replay

---

## Consumidor Kafka Particionado em .NET

### Modelo Mental

```
Topic: security-events (6 partições)
Consumer Group: dotnet-security-consumer

Instância 1 (2 workers):          Instância 2 (2 workers):
  Task → Partition 0                 Task → Partition 2
  Task → Partition 1                 Task → Partition 3
```

### Implementação com `Confluent.Kafka`

```csharp
public class PartitionedKafkaConsumer : BackgroundService
{
    private readonly IConsumer<string, string> _consumer;
    private readonly ConcurrentDictionary<TopicPartition, Channel<ConsumeResult<string, string>>> _channels = new();
    private readonly ConcurrentDictionary<TopicPartition, Task> _workers = new();

    public PartitionedKafkaConsumer(IConfiguration config)
    {
        var consumerConfig = new ConsumerConfig
        {
            BootstrapServers = config["Kafka:BootstrapServers"],
            GroupId = "dotnet-security-consumer",
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = false,
            PartitionAssignmentStrategy = PartitionAssignmentStrategy.CooperativeSticky,
        };

        _consumer = new ConsumerBuilder<string, string>(consumerConfig)
            .SetPartitionsAssignedHandler(OnPartitionsAssigned)
            .SetPartitionsRevokedHandler(OnPartitionsRevoked)
            .SetPartitionsLostHandler(OnPartitionsLost)
            .Build();
    }
}
```

### Diferença Crítica: Commit de Offset

```
Partição 0:  [offset 0] [offset 1] [offset 2] [offset 3] [offset 4]
                 ✅          ✅          ✅          ❌ falhou  ⏸ pausado
                                         ▲
                                   último commit
// Ao reiniciar, retoma do offset 3
```

### Rebalance com CooperativeSticky

```
Antes:              Nova instância sobe:      Depois:
Worker A: P0,P1,P2  →  A libera P2        →  Worker A: P0,P1
Worker B: P3,P4,P5  →  B libera P5        →  Worker B: P3,P4
                                           →  Worker C: P2,P5
```

---

## Flink Sink com AgenciaId como Chave

```java
KafkaSink<SecurityEvent> sink = KafkaSink.<SecurityEvent>builder()
    .setBootstrapServers("kafka:9092")
    .setRecordSerializer(
        KafkaRecordSerializationSchema.<SecurityEvent>builder()
            .setTopic("security-events")
            .setKeySerializationSchema(
                event -> event.getAgenciaId().getBytes(StandardCharsets.UTF_8)
            )
            .setValueSerializationSchema(new SecurityEventSerializer())
            .build()
    )
    .setDeliveryGuarantee(DeliveryGuarantee.AT_LEAST_ONCE)
    .build();
```

### Garantia End-to-End

```
Flink detecta evento          Consumer .NET processa
AgenciaId: 001                AgenciaId: 001
──────────────────            ──────────────────────
ALARM  t=10:00:01  ──┐        ALARM  t=10:00:01  ✅ 1º
PANIC  t=10:00:03  ──┤──P2──► PANIC  t=10:00:03  ✅ 2º
RESET  t=10:00:07  ──┘        RESET  t=10:00:07  ✅ 3º
```

---

## Agrupando Matches Correlacionados

O Flink emite matches individuais — o agrupamento acontece no consumer usando o `correlationId`:

```
Partição (AgenciaId: 001):
  offset 10 → match1 { correlationId: A1, triggerEvent: A, matchedEvent: B1 }
  offset 11 → match2 { correlationId: A1, triggerEvent: A, matchedEvent: B2 }
  offset 12 → match3 { correlationId: A1, triggerEvent: A, matchedEvent: B3 }
```

### No Flink CEP

```java
patternStream.process(new PatternProcessFunction<Event, SecurityMatch>() {
    @Override
    public void processMatch(Map<String, List<Event>> match, Context ctx, Collector<SecurityMatch> out) {
        Event eventA = match.get("A").get(0);
        String correlationId = eventA.getId(); // próprio ID do evento trigger

        for (Event b : match.get("B")) {
            out.collect(SecurityMatch.builder()
                .correlationId(correlationId)
                .agenciaId(eventA.getAgenciaId())
                .triggerEvent(eventA)
                .matchedEvent(b)
                .detectedAt(ctx.timestamp())
                .build());
        }
    }
});
```

---

## Usando Valkey para Persistir Grupos

### Estrutura de Chaves no Valkey

```
match-group:A1          → Hash  | meta (agenciaId, triggerEvent, lastUpdate) + match:1, match:2...
match-group:A1:timer    → String| TTL = duração da janela da regra (ex: 600s)
```

### Hash Único com Fields por Match

```
HSET match-group:A1
  agenciaId:     "001"
  correlationId: "A1"
  triggerEvent:  "{ json }"
  match:1:       "{ json B1 }"
  match:2:       "{ json B2 }"
  match:3:       "{ json B3 }"
  lastUpdate:    "2024-01-15T..."
```

- **`HSET`** — O(1) por field (append atômico, sem race condition)
- **`HGETALL`** — O(N) no flush (acontece uma única vez por grupo)
- **TTL fixo na criação** — nunca renovar no AddMatch

### Keyspace Notifications para Detectar Fim de Janela

```bash
# valkey.conf
notify-keyspace-events "Ex"
```

```csharp
await subscriber.SubscribeAsync(
    "__keyevent@0__:expired",
    async (_, key) =>
    {
        if (!key.ToString().StartsWith("match-group:")) return;
        var correlationId = key.ToString().Replace("match-group:", "").Replace(":timer", "");
        await occurrenceService.OnWindowExpiredAsync(correlationId);
    });
```

### Dois Gatilhos de Saída do Cache

```
TTL expira (janela da regra fechou)
  ├── DB UPDATE status: WINDOW_CLOSED
  └── SignalR OccurrenceWindowClosed

Operador fecha (OPEN → CLOSED)
  ├── REST PATCH /occurrences/{id}/close
  ├── DB UPDATE status: CLOSED
  ├── Valkey DEL match-group:A1
  └── SignalR OccurrenceClosed
```

---

## Arquitetura Completa

### Responsabilidade de Cada Componente

```
Flink CEP
  └── enriquece eventos (adiciona UUID na etapa de enriquecimento)
  └── detecta padrões A→[B1,B2,B3]
  └── emite matches para tópico security-matches
  └── emite todos os eventos para tópico security-events (side output → histórico)

Kafka Consumer (1 Task por partição)
  └── recebe match → gRPC → Worker

Worker (.NET)
  ├── gRPC Server   → CreateOccurrence, AddMatch (vindo do consumer)
  ├── REST API      → ações do operador (frontend)
  └── SignalR Hub   → notificações em tempo real (frontend)

  A cada operação:
    ├── 1. Valkey → cria/incrementa Hash (cache aside)
    ├── 2. DB     → INSERT/UPDATE (source of truth)
    └── 3. SignalR → notifica frontend

Frontend (JS/TS)
  ├── SignalR → recebe notificações em tempo real
  └── REST    → ações do operador
```

### Fluxo Completo

```
gRPC CreateOccurrence (primeiro match)
  ├── DB INSERT occurrence { id, trigger_event_id, status: OPEN, matches: [B1] }
  ├── Valkey HSET match-group:A.id { meta, match:1=B1 } EXPIRE 600s
  └── SignalR OccurrenceCreated

gRPC AddMatch (matches seguintes)
  ├── DB UPDATE WHERE trigger_event_id = A.id
  ├── Valkey HSET match-group:A.id match:N=BN  (sem renovar TTL)
  └── SignalR OccurrenceUpdated

TTL expira (t=10min)
  ├── DB UPDATE status: WINDOW_CLOSED
  └── SignalR OccurrenceWindowClosed

Operador fecha
  ├── REST PATCH /occurrences/{id}/close
  ├── DB UPDATE status: CLOSED
  ├── Valkey DEL match-group:A.id
  └── SignalR OccurrenceClosed
```

### Schema do Banco

```sql
CREATE TABLE occurrences (
    id                UUID PRIMARY KEY,         -- gerado pelo worker
    trigger_event_id  VARCHAR NOT NULL UNIQUE,  -- vem do Flink, usado nos updates
    agencia_id        VARCHAR NOT NULL,
    status            VARCHAR NOT NULL,
    matches           JSONB,
    created_at        TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_trigger_event_id ON occurrences (trigger_event_id);

CREATE TABLE events (
    id          VARCHAR PRIMARY KEY,  -- UUID gerado no enriquecimento do Flink
    agencia_id  VARCHAR NOT NULL,
    type        VARCHAR NOT NULL,
    payload     JSONB,
    occurred_at TIMESTAMPTZ
);
```

### Eventos SignalR para o Frontend

| Evento | Quando |
|---|---|
| `OccurrenceCreated` | Primeiro match chega |
| `OccurrenceUpdated` | Novo match adicionado |
| `OccurrenceWindowClosed` | TTL expirou (janela da regra fechou) |
| `OccurrenceClosed` | Operador fechou manualmente |

### Frontend TypeScript

```typescript
import * as signalR from "@microsoft/signalr";

const connection = new signalR.HubConnectionBuilder()
    .withUrl("https://worker/hubs/occurrences")
    .withAutomaticReconnect([0, 2000, 5000, 10000])
    .build();

connection.on("OccurrenceCreated", (o) => store.addOccurrence(o));
connection.on("OccurrenceUpdated", (o) => store.updateOccurrence(o));
connection.on("OccurrenceWindowClosed", (o) => store.markWindowClosed(o.correlationId));
connection.on("OccurrenceClosed", (o) => store.removeOccurrence(o.correlationId));

// Reconexão: ressincronizar via REST
connection.onreconnected(async () => {
    await syncOccurrencesFromRest();
});

await connection.start();
```

---

## CorrelationId

O `correlationId` nasce no Flink CEP a partir do **ID do evento trigger (A)**, gerado na **etapa de enriquecimento**:

```java
// Enriquecimento — antes do CEP
stream.map(event -> {
    if (event.getId() == null) {
        event.setId(UUID.randomUUID().toString()); // ou UUID v7
    }
    return event;
});

// CEP — usa o ID do evento A como correlationId
String correlationId = eventA.getId();
```

### Opções de ID

| | UUID v7 | Composto | Hash determinístico |
|---|---|---|---|
| Unicidade | ✅ Garantida | ⚠️ Risco de colisão | ✅ Garantida |
| Ordenável por tempo | ✅ | ✅ | ❌ |
| Idempotente | ❌ | ❌ | ✅ |

**Recomendação**: UUID v7 gerado no enriquecimento do Flink.

---

## Flink CEP — Tipos de Regras e Correlações

### Tipos de Correlação

| Operador | Ordem obrigatória | Eventos no meio | Uso |
|---|---|---|---|
| `next` | ✅ | ❌ | Sequência exata e imediata |
| `followedBy` | ✅ | ✅ | Sequência com gaps |
| `followedByAny` | ❌ | ✅ | Qualquer ordem |
| `notNext` | ✅ | ❌ | Ausência imediata |
| `notFollowedBy` | ✅ | ✅ | Ausência na janela |
| `times` | ✅ | ✅ | Repetição exata |
| `oneOrMore` | ✅ | ✅ | Repetição variável |
| `optional` | ✅ | ✅ | Evento facultativo |

### OR no CEP

Não existe OR nativo — duas formas de simular:

```java
// Opção 1: OR dentro da condição (mesmo slot)
Pattern.begin("A_or_B")
    .where(e -> e.getType().equals("ALARM")
             || e.getType().equals("INTRUSION"));

// Opção 2: union de dois PatternStreams
DataStream<SecurityMatch> matches = stream1.select(...)
    .union(stream2.select(...));
```

### AND no CEP

```java
// Múltiplos where = AND no mesmo evento
Pattern.begin("trigger")
    .where(e -> e.getType().equals("ALARM"))
    .where(e -> e.getAgenciaId().equals("001")); // AND implícito

// followedByAny = AND entre eventos distintos (qualquer ordem)
Pattern.begin("A").where(isAlarm())
    .followedByAny("B").where(isPanic())
    .within(Time.minutes(10));
```

### Exemplos Práticos

```java
// Alarme seguido de pânico em 10min
Pattern.begin("ALARM").where(isAlarm())
    .followedBy("PANIC").where(isPanic())
    .within(Time.minutes(10));

// Alarme sem reset em 5min
Pattern.begin("ALARM").where(isAlarm())
    .notFollowedBy("RESET").where(isReset())
    .within(Time.minutes(5));

// 3 acessos negados seguidos
Pattern.begin("DENIED").where(isAccessDenied())
    .times(3)
    .within(Time.minutes(1));

// Alarme seguido de 1 ou mais intrusões
Pattern.begin("ALARM").where(isAlarm())
    .followedByAny("INTRUSION").where(isIntrusion())
    .oneOrMore()
    .within(Time.minutes(10));
```

### AfterMatchSkipStrategy

```java
// NO_SKIP (padrão) — emite match para cada B na janela
Pattern.begin("A", AfterMatchSkipStrategy.noSkip())

// SKIP_PAST_LAST_EVENT — fecha após primeiro match
Pattern.begin("A", AfterMatchSkipStrategy.skipPastLastEvent())
```

### Regras Compostas com Peso (quando evento atende múltiplas regras)

Resolver no worker é mais simples — emite todos os matches e substitui pelo de maior peso:

```
Worker recebe match Regra1 → cria ocorrência
Worker recebe match Regra2 → mesmo correlationId → substitui (peso maior)
  ├── DB UPDATE rule = Regra2
  ├── Valkey HSET rule = Regra2
  └── SignalR OccurrenceUpdated
```

### Side Output para Histórico

```java
final OutputTag<Event> historyTag = new OutputTag<Event>("event-history"){};

// Enriquecimento emite para dois destinos
enrichedStream.process(new ProcessFunction<>() {
    public void processElement(Event event, Context ctx, Collector<Event> out) {
        event.setId(UUID.randomUUID().toString());
        out.collect(event);                  // fluxo principal → CEP
        ctx.output(historyTag, event);       // side output → histórico
    }
});

// Dois tópicos Kafka
enrichedStream.getSideOutput(historyTag)
    .addSink(kafkaSink("security-events")); // histórico completo
```

---

*Gerado a partir de conversa técnica — Março 2026*
