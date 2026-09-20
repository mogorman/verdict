defmodule JsonRules.Bench.Data do
  @moduledoc """
  A realistic, reusable ruleset for the benchmark suites — a transaction-risk
  model.

  It replaces the synthetic `f1..f20` dataset with:

    * **structured facts** (`transaction`, `customer`) read with JSONPath
      `path`s, plus scalar facts;
    * a **mix of operators** (`greaterThanInclusive`, `notEqual`,
      `lessThanInclusive`, `in`, `contains`), `all`/`any` trees, and a **named
      condition** (`high_risk`) referenced with `condition:`;
    * an optional **slow fact** (`fraud_score`): a constant by default, but with
      `slow: true` an expensive dynamic fact (`cache: false`) that is recomputed
      on every reference — the cost the `:parallel` scheduler overlaps.

  `engine/2` builds a fully-populated `JsonRules.Engine` for `count` rules.
  """
  alias JsonRules.Engine

  # Integer additions one slow `fraud_score` performs per reference.
  @slow_work 60_000

  @doc """
  Builds a `JsonRules.Engine` with `count` rules from the dataset.

  Options:

    * `:store` – store backend (default `:pure`).
    * `:slow` – when `true`, `fraud_score` is an expensive `cache: false` fact.
    * `:work` – cost of the slow fact in integer additions (default 60,000).
  """
  def engine(count, opts \\ []) do
    slow? = Keyword.get(opts, :slow, false)
    store = Keyword.get(opts, :store, :pure)
    work = Keyword.get(opts, :work, @slow_work)

    engine = Engine.new(store: store)

    engine =
      Enum.reduce(facts(slow?, work), engine, fn {id, definition, fact_opts}, acc ->
        Engine.add_fact(acc, id, definition, fact_opts)
      end)

    engine =
      Enum.reduce(conditions(), engine, fn {name, condition}, acc ->
        {:ok, acc} = Engine.set_condition(acc, name, condition)
        acc
      end)

    Enum.reduce(rules(count), engine, fn attrs, acc ->
      {:ok, acc, _rule} = Engine.add_rule(acc, attrs)
      acc
    end)
  end

  @doc "The facts as `{id, definition, fact_opts}` triples."
  def facts(slow? \\ false, work \\ @slow_work) do
    {fraud_def, fraud_opts} =
      if slow? do
        {slow_fact(work), [cache: false]}
      else
        {0.82, []}
      end

    [
      {
        "transaction",
        %{
          "amount" => 2_500,
          "currency" => "USD",
          "country" => "BR",
          "channel" => "mobile",
          "velocity" => 7
        },
        []
      },
      {"customer", %{"age" => 34, "account_age_days" => 420, "region" => "latam"}, []},
      {"recent_channels", ["mobile", "web"], []},
      {"fraud_score", fraud_def, fraud_opts}
    ]
  end

  @doc "The named conditions as `{name, condition_map}` pairs."
  def conditions do
    [
      {
        "high_risk",
        %{all: [%{fact: "fraud_score", operator: "greaterThanInclusive", value: 0.5}]}
      }
    ]
  end

  @doc "`count` rules, cycling a small base set and re-keying each by name."
  def rules(count) do
    base = base_rules()
    n = length(base)

    for i <- 1..count do
      base
      |> Enum.at(rem(i - 1, n))
      |> Map.put(:name, "rule_#{i}")
    end
  end

  @doc """
  A rule for the `engines` suite: a cheap head (highest condition priority, so it
  is evaluated first) that fails and decides its `all` early, followed by an
  expensive tail of slow `fraud_score` conditions. Under short-circuit the tail is
  skipped; under `strict: true` every tail condition is evaluated.
  """
  def short_circuit_rule(tail_width) do
    head = %{
      fact: "transaction",
      path: "$.amount",
      operator: "greaterThanInclusive",
      value: 10_000_000,
      priority: 100
    }

    tail =
      for _ <- 1..tail_width do
        %{fact: "fraud_score", operator: "greaterThanInclusive", value: 0.5, priority: 1}
      end

    %{
      priority: 10,
      event: %{type: "flag.heavy"},
      conditions: %{all: [head | tail]}
    }
  end

  @doc """
  Builds an engine of `count` `short_circuit_rule/1` rules over a slow
  `fraud_score` (the head reads a constant `transaction`).

  Options: `:store`, `:work`, `:tail_width`.
  """
  def engines_engine(count, opts \\ []) do
    store = Keyword.get(opts, :store, :pure)
    work = Keyword.get(opts, :work, @slow_work)
    tail_width = Keyword.get(opts, :tail_width, 3)

    engine = Engine.new(store: store)

    engine =
      Enum.reduce(facts(true, work), engine, fn {id, definition, fact_opts}, acc ->
        Engine.add_fact(acc, id, definition, fact_opts)
      end)

    Enum.reduce(1..count, engine, fn i, acc ->
      {:ok, acc, _rule} =
        Engine.add_rule(acc, short_circuit_rule(tail_width) |> Map.put(:name, "rule_#{i}"))

      acc
    end)
  end

  @doc """
  The four rule **shapes** for the `matrix` suite, as `{label, width, depth}`:

    * `width` — number of tail (leaf) conditions: 4 (narrow) or 16 (wide);
    * `depth` — `:flat` (all leaves sit directly under the top `all`) or `:nested`
      (the leaves are grouped into nested `any` sub-trees).

  So the shapes are narrow×flat, wide×flat, narrow×nested, and wide×nested — the
  "shallow / wide / deep / wide-deep" rule geometries. All share the same cheap
  deciding head, so they differ only in the tail's width and nesting.
  """
  def shapes do
    [
      {:shallow, 4, :flat},
      {:wide, 16, :flat},
      {:nested, 4, :nested},
      {:wide_nested, 16, :nested}
    ]
  end

  @doc """
  A `matrix` rule of a given `shape` (`:shallow`/`:wide`/`:nested`/`:wide_nested`).

  A cheap head (highest condition priority, so it is evaluated first) fails and
  decides the `all` early; the tail is the shape's leaves at distinct priorities,
  laid out `:flat` or `:nested`. Under short-circuit the tail is skipped; under
  `strict: true` every leaf is evaluated.

  `speed` selects the tail fact: `:slow` → the expensive `fraud_score`, `:fast` → a
  cheap `risk` constant.
  """
  def matrix_rule(shape, speed) do
    {width, depth} = shape_dims(shape)

    head = %{
      fact: "transaction",
      path: "$.amount",
      operator: "greaterThanInclusive",
      value: 10_000_000,
      priority: 100
    }

    %{
      priority: 10,
      event: %{type: "flag.matrix"},
      conditions: %{all: [head | build_body(width, depth, speed)]}
    }
  end

  @doc """
  Builds a `matrix` engine of `count` rules of a given `shape`.

  Options: `:store`, `:shape` (`:shallow`/`:wide`/`:nested`/`:wide_nested`),
  `:speed` (`:slow`/`:fast`), `:cache` (boolean, applied to the dynamic tail fact),
  `:work` (cost of the slow fact).
  """
  def matrix_engine(count, opts \\ []) do
    store = Keyword.get(opts, :store, :pure)
    speed = Keyword.get(opts, :speed, :slow)
    cache = Keyword.get(opts, :cache, true)
    shape = Keyword.get(opts, :shape, :shallow)
    work = Keyword.get(opts, :work, @slow_work)

    engine = Engine.new(store: store)

    engine =
      Enum.reduce(
        [
          {
            "transaction",
            %{
              "amount" => 2_500,
              "currency" => "USD",
              "country" => "BR",
              "channel" => "mobile",
              "velocity" => 7
            },
            []
          },
          {"fraud_score", slow_fact(work), [cache: cache]},
          {"risk", fn _params, _almanac -> 42 end, [cache: cache]}
        ],
        engine,
        fn {id, definition, fact_opts}, acc ->
          Engine.add_fact(acc, id, definition, fact_opts)
        end
      )

    Enum.reduce(1..count, engine, fn i, acc ->
      {:ok, acc, _rule} =
        Engine.add_rule(acc, matrix_rule(shape, speed) |> Map.put(:name, "rule_#{i}"))

      acc
    end)
  end

  defp build_body(width, :flat, speed) do
    for i <- 1..width, do: Map.put(tail_condition(speed), :priority, i)
  end

  # `:nested` groups the leaves into `any` pairs, adding a nesting level while
  # keeping the same number of leaves and the same priorities.
  defp build_body(width, :nested, speed) do
    for pair <- Enum.chunk_by(1..width, fn i -> div(i - 1, 2) end) do
      %{any: Enum.map(pair, fn i -> Map.put(tail_condition(speed), :priority, i) end)}
    end
  end

  defp shape_dims(shape) do
    case List.keyfind(shapes(), shape, 0) do
      {_label, width, depth} -> {width, depth}
      nil -> raise "unknown matrix shape: #{inspect(shape)}"
    end
  end

  defp tail_condition(:slow), do: %{fact: "fraud_score", operator: "lessThan", value: 0.9}
  defp tail_condition(:fast), do: %{fact: "risk", operator: "lessThan", value: 100}

  # The slow fact does real work (`work` integer additions) and then returns the
  # same value as the fast fact (0.82), so the fast and slow engines evaluate the
  # identical rules and differ only in computation cost.
  defp slow_fact(work) do
    fn _params, _almanac ->
      cost(work)
      0.82
    end
  end

  defp cost(work), do: Enum.reduce(1..work, 0, fn i, acc -> acc + i end)

  defp base_rules do
    [
      %{
        priority: 50,
        event: %{type: "flag.review"},
        conditions: %{
          all: [
            %{
              fact: "transaction",
              path: "$.amount",
              operator: "greaterThanInclusive",
              value: 1000
            },
            %{fact: "transaction", path: "$.country", operator: "notEqual", value: "US"},
            %{condition: "high_risk"}
          ]
        }
      },
      %{
        priority: 40,
        event: %{type: "flag.restrict"},
        conditions: %{
          all: [
            %{
              fact: "transaction",
              path: "$.velocity",
              operator: "greaterThanInclusive",
              value: 5
            },
            %{fact: "recent_channels", operator: "contains", value: "mobile"},
            %{condition: "high_risk"}
          ]
        }
      },
      %{
        priority: 20,
        event: %{type: "flag.watch"},
        conditions: %{
          all: [
            %{
              any: [
                %{
                  fact: "customer",
                  path: "$.account_age_days",
                  operator: "lessThanInclusive",
                  value: 90
                },
                %{fact: "customer", path: "$.region", operator: "in", value: ["latam", "emea"]}
              ]
            },
            %{condition: "high_risk"}
          ]
        }
      }
    ]
  end
end
