defmodule Explorer.Series do
  @moduledoc """
  The Series struct and API.

  A series can be of the following data types:

    * `:float` - 64-bit floating point number
    * `:integer` - 64-bit signed integer
    * `:boolean` - Boolean
    * `:string` - UTF-8 encoded binary
    * `:date` - Date type that unwraps to `Elixir.Date`
    * `:datetime` - DateTime type that unwraps to `Elixir.NaiveDateTime`

  A series must consist of a single data type only. Series are nullable, but may not consist only of
  nils.

  Many functions only apply to certain dtypes. Where that is the case, you'll find a `Supported
  dtypes` section in the function documentation and the function will raise an `ArgumentError` if
  a series with an invalid dtype is used.
  """

  import Kernel, except: [and: 2]

  alias __MODULE__, as: Series
  alias Kernel, as: K
  alias Explorer.Shared

  @valid_dtypes Explorer.Shared.dtypes()

  @type dtype :: :integer | :float | :boolean | :string | :date | :datetime
  @type t :: %Series{data: Explorer.Backend.Series.t(), dtype: dtype()}
  @type lazy_t :: %Series{data: Explorer.Backend.LazySeries.t(), dtype: dtype()}

  @enforce_keys [:data, :dtype]
  defstruct [:data, :dtype]

  @behaviour Access

  @compile {:no_warn_undefined, Nx}

  defguardp numeric_dtype?(dtype) when dtype in [:float, :integer]
  defguardp numeric_or_bool_dtype?(dtype) when dtype in [:float, :integer, :boolean]
  defguardp numeric_or_date_dtype?(dtype) when dtype in [:float, :integer, :date, :datetime]

  @impl true
  def fetch(series, idx) when is_integer(idx), do: {:ok, fetch!(series, idx)}
  def fetch(series, indices) when is_list(indices), do: {:ok, slice(series, indices)}
  def fetch(series, %Range{} = range), do: {:ok, slice(series, range)}

  @impl true
  def pop(series, idx) when is_integer(idx) do
    mask = 0..(size(series) - 1) |> Enum.map(&(&1 != idx)) |> from_list()
    value = fetch!(series, idx)
    series = mask(series, mask)
    {value, series}
  end

  def pop(series, indices) when is_list(indices) do
    mask = 0..(size(series) - 1) |> Enum.map(&(&1 not in indices)) |> from_list()
    value = slice(series, indices)
    series = mask(series, mask)
    {value, series}
  end

  def pop(series, %Range{} = range) do
    mask = 0..(size(series) - 1) |> Enum.map(&(&1 not in range)) |> from_list()
    value = slice(series, range)
    series = mask(series, mask)
    {value, series}
  end

  @impl true
  def get_and_update(series, idx, fun) when is_integer(idx) do
    value = fetch!(series, idx)
    {current_value, new_value} = fun.(value)
    new_data = series |> to_list() |> List.replace_at(idx, new_value) |> from_list()
    {current_value, new_data}
  end

  # Conversion

  @doc """
  Creates a new series from a list.

  The list must consist of a single data type and nils. It is possible to have
  a list of only nil values. In this case, the list will have the `:dtype` of float.

  ## Options

    * `:backend` - The backend to allocate the series on.
    * `:dtype` - Cast the series to a given `:dtype`. By default this is `nil`, which means
    that Explorer will infer the type from the values in the list.

  ## Examples

  Explorer will infer the type from the values in the list.

      iex> Explorer.Series.from_list([1, 2, 3])
      #Explorer.Series<
        integer[3]
        [1, 2, 3]
      >

  Series are nullable, so you may also include nils.

      iex> Explorer.Series.from_list([1.0, nil, 2.5, 3.1])
      #Explorer.Series<
        float[4]
        [1.0, nil, 2.5, 3.1]
      >

  A mix of integers and floats will be downcasted to a float.

      iex> Explorer.Series.from_list([1, 2.0])
      #Explorer.Series<
        float[2]
        [1.0, 2.0]
      >

  Trying to create a "nil" series will, by default, result in a series of floats.

      iex> Explorer.Series.from_list([nil, nil])
      #Explorer.Series<
        float[2]
        [nil, nil]
      >

  You can specify the desired `dtype` for a series with the `:dtype` option.

      iex> Explorer.Series.from_list([nil, nil], dtype: :integer)
      #Explorer.Series<
        integer[2]
        [nil, nil]
      >

      iex> Explorer.Series.from_list([1, nil], dtype: :string)
      #Explorer.Series<
        string[2]
        ["1", nil]
      >

  It is possible to create a series of `:datetime` from a list of microseconds since Unix Epoch.

      iex> Explorer.Series.from_list([1649883642 * 1_000 * 1_000], dtype: :datetime)
      #Explorer.Series<
        datetime[1]
        [2022-04-13 21:00:42.000000]
      >

  Mixing non-numeric data types will raise an ArgumentError.

      iex> Explorer.Series.from_list([1, "a"])
      ** (ArgumentError) the value "a" does not match the inferred series dtype :integer
  """
  @doc type: :transformation
  @spec from_list(list :: list(), opts :: Keyword.t()) :: Series.t()
  def from_list(list, opts \\ []) do
    backend = backend_from_options!(opts)
    type = Shared.check_types!(list)
    {list, type} = Shared.cast_numerics(list, type)
    series = backend.from_list(list, type)

    case {type, check_optional_dtype!(opts[:dtype])} do
      {t, t} -> series
      {_t, nil} -> series
      {_, other} -> cast(series, other)
    end
  end

  defp check_optional_dtype!(nil), do: nil
  defp check_optional_dtype!(dtype) when dtype in @valid_dtypes, do: dtype

  defp check_optional_dtype!(dtype) do
    raise ArgumentError, "unsupported datatype: #{inspect(dtype)}"
  end

  @doc """
  Converts a series to a list.

  ## Examples

      iex> series = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_list(series)
      [1, 2, 3]
  """
  @doc type: :transformation
  @spec to_list(series :: Series.t()) :: list()
  def to_list(series), do: Shared.apply_impl(series, :to_list)

  @doc """
  Converts a series to an enumerable.

  ## Examples

      iex> series = Explorer.Series.from_list([1, 2, 3])
      iex> series |> Explorer.Series.to_enum() |> Enum.to_list()
      [1, 2, 3]
  """
  @doc type: :transformation
  @spec to_enum(series :: Series.t()) :: Enumerable.t()
  def to_enum(series), do: Shared.apply_impl(series, :to_enum)

  @doc """
  Converts a `t:Nx.Tensor.t/0` to a series.

  > #### Warning {: .warning}
  >
  > `Nx` is an optional dependency. You will need to ensure it's installed to use this function.

  ## Examples

      iex> tensor = Nx.tensor([1, 2, 3])
      iex> Explorer.Series.from_tensor(tensor)
      #Explorer.Series<
        integer[3]
        [1, 2, 3]
      >

      iex> tensor = Nx.tensor([1.0, 2.0, 3.0])
      iex> Explorer.Series.from_tensor(tensor)
      #Explorer.Series<
        float[3]
        [1.0, 2.0, 3.0]
      >
  """
  @doc type: :transformation
  @spec from_tensor(tensor :: Nx.Tensor.t(), opts :: Keyword.t()) :: Series.t()
  def from_tensor(tensor, opts \\ []) do
    backend = backend_from_options!(opts)

    type =
      case Nx.type(tensor) do
        {t, _} when t in [:s, :u] -> :integer
        {t, _} when t in [:f, :bf] -> :float
      end

    tensor |> Nx.to_flat_list() |> backend.from_list(type)
  end

  @doc """
  Converts a series to a `t:Nx.Tensor.t/0`.

  Options are passed directly to `Nx.tensor/2`.

  ## Supported dtypes

    * `:float`
    * `:integer`

  > #### Warning {: .warning}
  >
  > `Nx` is an optional dependency. You will need to ensure it's installed to use this function.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_tensor(s)
      #Nx.Tensor<
        s64[3]
        [1, 2, 3]
      >

  Tensor options can be passed directly to `to_tensor/2`.

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.to_tensor(s, names: [:y], type: {:f, 64})
      #Nx.Tensor<
        f64[y: 3]
        [1.0, 2.0, 3.0]
      >
  """
  @doc type: :transformation
  @spec to_tensor(series :: Series.t(), tensor_opts :: Keyword.t()) :: Nx.Tensor.t()
  def to_tensor(series, tensor_opts \\ []), do: series |> to_list() |> Nx.tensor(tensor_opts)

  @doc """
  Cast the series to another type.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :string)
      #Explorer.Series<
        string[3]
        ["1", "2", "3"]
      >

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :float)
      #Explorer.Series<
        float[3]
        [1.0, 2.0, 3.0]
      >

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :date)
      #Explorer.Series<
        date[3]
        [1970-01-02, 1970-01-03, 1970-01-04]
      >

  Note that `datetime` is represented as an integer of microseconds since Unix Epoch (1970-01-01 00:00:00).

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :datetime)
      #Explorer.Series<
        datetime[3]
        [1970-01-01 00:00:00.000001, 1970-01-01 00:00:00.000002, 1970-01-01 00:00:00.000003]
      >

      iex> s = Explorer.Series.from_list([1649883642 * 1_000 * 1_000])
      iex> Explorer.Series.cast(s, :datetime)
      #Explorer.Series<
        datetime[1]
        [2022-04-13 21:00:42.000000]
      >

  `cast/2` will return the series as a no-op if you try to cast to the same dtype.

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.cast(s, :integer)
      #Explorer.Series<
        integer[3]
        [1, 2, 3]
      >
  """
  @doc type: :element_wise
  @spec cast(series :: Series.t(), dtype :: dtype()) :: Series.t()
  def cast(%Series{dtype: dtype} = series, dtype), do: series
  def cast(series, dtype), do: Shared.apply_impl(series, :cast, [dtype])

  # Introspection

  @doc """
  Returns the data type of the series.

  A series can be of the following data types:

    * `:float` - 64-bit floating point number
    * `:integer` - 64-bit signed integer
    * `:boolean` - Boolean
    * `:string` - UTF-8 encoded binary
    * `:date` - Date type that unwraps to `Elixir.Date`
    * `:datetime` - DateTime type that unwraps to `Elixir.NaiveDateTime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.dtype(s)
      :integer

      iex> s = Explorer.Series.from_list(["a", nil, "b", "c"])
      iex> Explorer.Series.dtype(s)
      :string
  """
  @doc type: :introspection
  @spec dtype(series :: Series.t()) :: dtype()
  def dtype(%Series{dtype: dtype}), do: dtype

  @doc """
  Returns the size of the series.

  ## Examples

      iex> s = Explorer.Series.from_list([~D[1999-12-31], ~D[1989-01-01]])
      iex> Explorer.Series.size(s)
      2
  """
  @doc type: :introspection
  @spec size(series :: Series.t()) :: integer()
  def size(series), do: Shared.apply_impl(series, :size)

  @doc """
  Returns the memory type of the series.

  This function mirrors the `Nx` types.

  It returns something in the shape of `atom()` or `{atom(), bits_size}`.

  The possible memtypes are:

  * `:utf8` for strings.
  * `:u` for unsigned integers.
  * `:s` for signed integers.
  * `:f` for floats.

  ## Examples

      iex> s = Explorer.Series.from_list(["Alice", "Bob"])
      iex> Explorer.Series.memtype(s)
      :utf8

      iex> s = Explorer.Series.from_list([1, 2, 3, 4])
      iex> Explorer.Series.memtype(s)
      {:s, 64}

      iex> s = Explorer.Series.from_list([~D[1999-12-31], ~D[1989-01-01]])
      iex> Explorer.Series.memtype(s)
      {:s, 32}

      iex> s = Explorer.Series.from_list([1.2, 2.3, 3.5, 4.5])
      iex> Explorer.Series.memtype(s)
      {:f, 64}

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.memtype(s)
      {:u, 8}

  """
  @doc type: :introspection
  @spec memtype(series :: Series.t()) :: atom() | {atom(), non_neg_integer()}
  def memtype(series), do: Shared.apply_impl(series, :memtype)

  # Slice and dice

  @doc """
  Returns the first N elements of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.head(s)
      #Explorer.Series<
        integer[10]
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      >
  """
  @doc type: :transformation
  @spec head(series :: Series.t(), n_elements :: integer()) :: Series.t()
  def head(series, n_elements \\ 10), do: Shared.apply_impl(series, :head, [n_elements])

  @doc """
  Returns the last N elements of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.tail(s)
      #Explorer.Series<
        integer[10]
        [91, 92, 93, 94, 95, 96, 97, 98, 99, 100]
      >
  """
  @doc type: :transformation
  @spec tail(series :: Series.t(), n_elements :: integer()) :: Series.t()
  def tail(series, n_elements \\ 10), do: Shared.apply_impl(series, :tail, [n_elements])

  @doc """
  Returns the first element of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.first(s)
      1
  """
  @doc type: :transformation
  @spec first(series :: Series.t()) :: any()
  def first(series), do: Shared.apply_impl(series, :first, [])

  @doc """
  Returns the last element of the series.

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.last(s)
      100
  """
  @doc type: :transformation
  @spec last(series :: Series.t()) :: any()
  def last(series), do: Shared.apply_impl(series, :last, [])

  @doc """
  Returns a random sample of the series.

  If given an integer as the second argument, it will return N samples. If given a float, it will
  return that proportion of the series.

  Can sample with or without replacement.

  ## Options

    * `replacement` - If set to `true`, each sample will be independent and therefore values may repeat.
      Required to be `true` for `n` greater then the number of rows in the series or `frac` > 1.0. (default: `false`)
    * `seed` - An integer to be used as a random seed. If nil, a random value between 1 and 1e12 will be used. (default: nil)

  ## Examples

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 10, seed: 100)
      #Explorer.Series<
        integer[10]
        [72, 33, 15, 4, 16, 49, 23, 96, 45, 47]
      >

      iex> s = 1..100 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.sample(s, 0.05, seed: 100)
      #Explorer.Series<
        integer[5]
        [68, 24, 6, 8, 36]
      >
  """
  @doc type: :transformation
  @spec sample(series :: Series.t(), n_or_frac :: number(), opts :: Keyword.t()) ::
          Series.t()
  def sample(series, n_or_frac, opts \\ [])

  def sample(series, n, opts) when is_integer(n) do
    opts = Keyword.validate!(opts, replacement: false, seed: Enum.random(1..1_000_000_000_000))

    size = size(series)

    case {n > size, opts[:replacement]} do
      {true, false} ->
        raise ArgumentError,
              "in order to sample more elements than are in the series (#{size}), sampling " <>
                "`replacement` must be true"

      _ ->
        :ok
    end

    Shared.apply_impl(series, :sample, [n, opts[:replacement], opts[:seed]])
  end

  def sample(series, frac, opts) when is_float(frac) do
    size = size(series)
    n = round(frac * size)
    sample(series, n, opts)
  end

  @doc """
  Takes every *n*th value in this series, returned as a new series.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> s |> Explorer.Series.take_every(2)
      #Explorer.Series<
        integer[5]
        [1, 3, 5, 7, 9]
      >

  If *n* is bigger than the size of the series, the result is a new series with only the first value of the supplied series.

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> s |> Explorer.Series.take_every(20)
      #Explorer.Series<
        integer[1]
        [1]
      >
  """
  @doc type: :transformation
  @spec take_every(series :: Series.t(), every_n :: integer()) :: Series.t()
  def take_every(series, every_n), do: Shared.apply_impl(series, :take_every, [every_n])

  @doc """
  Filters a series with a mask.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1,2,3])
      iex> s2 = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.mask(s1, s2)
      #Explorer.Series<
        integer[2]
        [1, 3]
      >
  """
  @doc type: :transformation
  @spec mask(series :: Series.t(), mask :: Series.t()) :: Series.t()
  def mask(series, %Series{} = mask), do: Shared.apply_impl(series, :mask, [mask])

  @doc """
  Returns a slice of the series, with `size` elements starting at `offset`.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, 1, 2)
      #Explorer.Series<
        integer[2]
        [2, 3]
      >

  Negative offsets count from the end of the series.

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, -3, 2)
      #Explorer.Series<
        integer[2]
        [3, 4]
      >

  If the size would run past the end of the series, the result may be shorter than the size.

      iex> s = Explorer.Series.from_list([1, 2, 3, 4, 5])
      iex> Explorer.Series.slice(s, -3, 4)
      #Explorer.Series<
        integer[3]
        [3, 4, 5]
      >
  """
  @doc type: :transformation
  @spec slice(series :: Series.t(), offset :: integer(), size :: integer()) :: Series.t()
  def slice(series, offset, size), do: Shared.apply_impl(series, :slice, [offset, size])

  @doc """
  Returns the elements at the given indices as a new series.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.slice(s, [0, 2])
      #Explorer.Series<
        string[2]
        ["a", "c"]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.slice(s, 1..2)
      #Explorer.Series<
        string[2]
        ["b", "c"]
      >
  """
  @doc type: :transformation
  @spec slice(series :: Series.t(), indices :: [integer()] | Range.t()) :: Series.t()
  def slice(series, indices) when is_list(indices),
    do: Shared.apply_impl(series, :slice, [indices])

  def slice(series, %Range{} = range),
    do: slice(series, Enum.slice(0..(size(series) - 1)//1, range))

  @doc """
  Returns the value of the series at the given index.

  This function will raise an error in case the index
  is out of bounds.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.fetch!(s, 2)
      "c"

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.fetch!(s, 4)
      ** (ArgumentError) index 4 out of bounds for series of size 3
  """
  @doc type: :transformation
  @spec fetch!(series :: Series.t(), idx :: integer()) :: any()
  def fetch!(series, idx) do
    s_len = size(series)

    if idx > s_len - 1 || idx < -s_len,
      do: raise(ArgumentError, "index #{idx} out of bounds for series of size #{s_len}")

    Shared.apply_impl(series, :fetch!, [idx])
  end

  @doc """
  Concatenate one or more series.

  The dtypes must match unless all are numeric, in which case all series will be downcast to float.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([4, 5, 6])
      iex> Explorer.Series.concat([s1, s2])
      #Explorer.Series<
        integer[6]
        [1, 2, 3, 4, 5, 6]
      >

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([4.0, 5.0, 6.4])
      iex> Explorer.Series.concat(s1, s2)
      #Explorer.Series<
        float[6]
        [1.0, 2.0, 3.0, 4.0, 5.0, 6.4]
      >
  """
  @doc type: :transformation
  @spec concat([Series.t()]) :: Series.t()
  def concat([%Series{} = h | t] = _series) do
    Enum.reduce(t, h, &concat_reducer/2)
  end

  @doc """
  Concatenate one or more series.

  `concat(s1, s2)` is equivalent to `concat([s1, s2])`.
  """
  @doc type: :transformation
  @spec concat(s1 :: Series.t(), s2 :: Series.t()) :: Series.t()
  def concat(%Series{} = s1, %Series{} = s2),
    do: concat([s1, s2])

  def concat(%Series{} = s1, [%Series{} | _] = series),
    do: concat([s1 | series])

  defp concat_reducer(%Series{dtype: dtype} = s, %Series{dtype: dtype} = acc),
    do: Shared.apply_impl(acc, :concat, [s])

  defp concat_reducer(%Series{dtype: s_dtype} = s, %Series{dtype: acc_dtype} = acc)
       when K.and(s_dtype == :float, acc_dtype == :integer),
       do: acc |> cast(:float) |> Shared.apply_impl(:concat, [s])

  defp concat_reducer(%Series{dtype: s_dtype} = s, %Series{dtype: acc_dtype} = acc)
       when K.and(s_dtype == :integer, acc_dtype == :float),
       do: Shared.apply_impl(acc, :concat, [cast(s, :float)])

  defp concat_reducer(%Series{dtype: dtype1}, %Series{dtype: dtype2}),
    do: raise(ArgumentError, "dtypes must match, found #{dtype1} and #{dtype2}")

  @doc """
  Finds the first non-missing element at each position.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, nil, nil])
      iex> s2 = Explorer.Series.from_list([1, 2, nil, 4])
      iex> s3 = Explorer.Series.from_list([nil, nil, 3, 4])
      iex> Explorer.Series.coalesce([s1, s2, s3])
      #Explorer.Series<
        integer[4]
        [1, 2, 3, 4]
      >
  """
  @doc type: :element_wise
  @spec coalesce([Series.t()]) :: Series.t()
  def coalesce([%Series{} = h | t]),
    do: Enum.reduce(t, h, &coalesce(&2, &1))

  @doc """
  Finds the first non-missing element at each position.

  `coalesce(s1, s2)` is equivalent to `coalesce([s1, s2])`.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, nil, 3, nil])
      iex> s2 = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.coalesce(s1, s2)
      #Explorer.Series<
        integer[4]
        [1, 2, 3, 4]
      >

      iex> s1 = Explorer.Series.from_list(["foo", nil, "bar", nil])
      iex> s2 = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.coalesce(s1, s2)
      ** (ArgumentError) cannot invoke Explorer.Series.coalesce/2 with mismatched dtypes: string and integer.
  """
  @doc type: :transformation
  @spec coalesce(s1 :: Series.t(), s2 :: Series.t()) :: Series.t()
  def coalesce(s1, s2) do
    :ok = check_dtypes_for_coalesce!(s1, s2)

    Shared.apply_impl(s1, :coalesce, [s2])
  end

  # Aggregation

  @doc """
  Gets the sum of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:boolean`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.sum(s)
      6

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.sum(s)
      6.0

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.sum(s)
      2

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.sum(s)
      ** (ArgumentError) Explorer.Series.sum/1 not implemented for dtype :date. Valid dtypes are [:integer, :float, :boolean].
  """
  @doc type: :aggregation
  @spec sum(series :: Series.t()) :: number()
  def sum(%Series{dtype: dtype} = series) when numeric_or_bool_dtype?(dtype),
    do: Shared.apply_impl(series, :sum)

  def sum(%Series{dtype: dtype}), do: dtype_error("sum/1", dtype, [:integer, :float, :boolean])

  @doc """
  Gets the minimum value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.min(s)
      1

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.min(s)
      1.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.min(s)
      ~D[1999-12-31]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.min(s)
      ~N[1999-12-31 00:00:00.000000]

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.min(s)
      ** (ArgumentError) Explorer.Series.min/1 not implemented for dtype :string. Valid dtypes are [:integer, :float, :date, :datetime].
  """
  @doc type: :aggregation
  @spec min(series :: Series.t()) :: number() | Date.t() | NaiveDateTime.t()
  def min(%Series{dtype: dtype} = series) when numeric_or_date_dtype?(dtype),
    do: Shared.apply_impl(series, :min)

  def min(%Series{dtype: dtype}),
    do: dtype_error("min/1", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Gets the maximum value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.max(s)
      3

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.max(s)
      3.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.max(s)
      ~D[2021-01-01]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.max(s)
      ~N[2021-01-01 00:00:00.000000]

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.max(s)
      ** (ArgumentError) Explorer.Series.max/1 not implemented for dtype :string. Valid dtypes are [:integer, :float, :date, :datetime].
  """
  @doc type: :aggregation
  @spec max(series :: Series.t()) :: number() | Date.t() | NaiveDateTime.t()
  def max(%Series{dtype: dtype} = series) when numeric_or_date_dtype?(dtype),
    do: Shared.apply_impl(series, :max)

  def max(%Series{dtype: dtype}),
    do: dtype_error("max/1", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Gets the mean value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.mean(s)
      2.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.mean(s)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.mean(s)
      ** (ArgumentError) Explorer.Series.mean/1 not implemented for dtype :date. Valid dtypes are [:integer, :float].
  """
  @doc type: :aggregation
  @spec mean(series :: Series.t()) :: float()
  def mean(%Series{dtype: dtype} = series) when numeric_dtype?(dtype),
    do: Shared.apply_impl(series, :mean)

  def mean(%Series{dtype: dtype}), do: dtype_error("mean/1", dtype, [:integer, :float])

  @doc """
  Gets the median value of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.median(s)
      2.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.median(s)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.median(s)
      ** (ArgumentError) Explorer.Series.median/1 not implemented for dtype :date. Valid dtypes are [:integer, :float].
  """
  @doc type: :aggregation
  @spec median(series :: Series.t()) :: float()
  def median(%Series{dtype: dtype} = series) when numeric_dtype?(dtype),
    do: Shared.apply_impl(series, :median)

  def median(%Series{dtype: dtype}), do: dtype_error("median/1", dtype, [:integer, :float])

  @doc """
  Gets the variance of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.var(s)
      1.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.var(s)
      1.0

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.var(s)
      ** (ArgumentError) Explorer.Series.var/1 not implemented for dtype :datetime. Valid dtypes are [:integer, :float].
  """
  @doc type: :aggregation
  @spec var(series :: Series.t()) :: float()
  def var(%Series{dtype: dtype} = series) when numeric_dtype?(dtype),
    do: Shared.apply_impl(series, :var)

  def var(%Series{dtype: dtype}), do: dtype_error("var/1", dtype, [:integer, :float])

  @doc """
  Gets the standard deviation of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.std(s)
      1.0

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.std(s)
      1.0

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.std(s)
      ** (ArgumentError) Explorer.Series.std/1 not implemented for dtype :string. Valid dtypes are [:integer, :float].
  """
  @doc type: :aggregation
  @spec std(series :: Series.t()) :: float()
  def std(%Series{dtype: dtype} = series) when numeric_dtype?(dtype),
    do: Shared.apply_impl(series, :std)

  def std(%Series{dtype: dtype}), do: dtype_error("std/1", dtype, [:integer, :float])

  @doc """
  Gets the given quantile of the series.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 3])
      iex> Explorer.Series.quantile(s, 0.2)
      1

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 3.0])
      iex> Explorer.Series.quantile(s, 0.5)
      2.0

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.quantile(s, 0.5)
      ~D[2021-01-01]

      iex> s = Explorer.Series.from_list([~N[2021-01-01 00:00:00], ~N[1999-12-31 00:00:00]])
      iex> Explorer.Series.quantile(s, 0.5)
      ~N[2021-01-01 00:00:00.000000]

      iex> s = Explorer.Series.from_list([true, false, true])
      iex> Explorer.Series.quantile(s, 0.5)
      ** (ArgumentError) Explorer.Series.quantile/2 not implemented for dtype :boolean. Valid dtypes are [:integer, :float, :date, :datetime].
  """
  @doc type: :aggregation
  @spec quantile(series :: Series.t(), quantile :: float()) :: any()
  def quantile(%Series{dtype: dtype} = series, quantile)
      when numeric_or_date_dtype?(dtype),
      do: Shared.apply_impl(series, :quantile, [quantile])

  def quantile(%Series{dtype: dtype}, _),
    do: dtype_error("quantile/2", dtype, [:integer, :float, :date, :datetime])

  # Cumulative

  @doc """
  Calculates the cumulative maximum of the series.

  Optionally, can fill in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = [1, 2, 3, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_max(s)
      #Explorer.Series<
        integer[4]
        [1, 2, 3, 4]
      >

      iex> s = [1, 2, nil, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_max(s)
      #Explorer.Series<
        integer[4]
        [1, 2, nil, 4]
      >
  """
  @doc type: :window
  @spec cumulative_max(series :: Series.t(), opts :: Keyword.t()) :: Series.t()
  def cumulative_max(series, opts \\ [])

  def cumulative_max(%Series{dtype: dtype} = series, opts)
      when numeric_or_date_dtype?(dtype) do
    opts = Keyword.validate!(opts, reverse: false)
    Shared.apply_impl(series, :cumulative_max, [opts[:reverse]])
  end

  def cumulative_max(%Series{dtype: dtype}, _),
    do: dtype_error("cumulative_max/2", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Calculates the cumulative minimum of the series.

  Optionally, can fill in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = [1, 2, 3, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_min(s)
      #Explorer.Series<
        integer[4]
        [1, 1, 1, 1]
      >

      iex> s = [1, 2, nil, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_min(s)
      #Explorer.Series<
        integer[4]
        [1, 1, nil, 1]
      >
  """
  @doc type: :window
  @spec cumulative_min(series :: Series.t(), opts :: Keyword.t()) :: Series.t()
  def cumulative_min(series, opts \\ [])

  def cumulative_min(%Series{dtype: dtype} = series, opts)
      when numeric_or_date_dtype?(dtype) do
    opts = Keyword.validate!(opts, reverse: false)
    Shared.apply_impl(series, :cumulative_min, [opts[:reverse]])
  end

  def cumulative_min(%Series{dtype: dtype}, _),
    do: dtype_error("cumulative_min/2", dtype, [:integer, :float, :date, :datetime])

  @doc """
  Calculates the cumulative sum of the series.

  Optionally, can fill in reverse.

  Does not fill nil values. See `fill_missing/2`.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:boolean`

  ## Examples

      iex> s = [1, 2, 3, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_sum(s)
      #Explorer.Series<
        integer[4]
        [1, 3, 6, 10]
      >

      iex> s = [1, 2, nil, 4] |> Explorer.Series.from_list()
      iex> Explorer.Series.cumulative_sum(s)
      #Explorer.Series<
        integer[4]
        [1, 3, nil, 7]
      >
  """
  @doc type: :window
  @spec cumulative_sum(series :: Series.t(), opts :: Keyword.t()) :: Series.t()
  def cumulative_sum(series, opts \\ [])

  def cumulative_sum(%Series{dtype: dtype} = series, opts)
      when numeric_dtype?(dtype) do
    opts = Keyword.validate!(opts, reverse: false)
    Shared.apply_impl(series, :cumulative_sum, [opts[:reverse]])
  end

  def cumulative_sum(%Series{dtype: dtype}, _),
    do: dtype_error("cumulative_sum/2", dtype, [:integer, :float])

  # Local minima/maxima

  @doc """
  Returns a boolean mask with `true` where the 'peaks' (series max or min, default max) are.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, 4, 1, 4])
      iex> Explorer.Series.peaks(s)
      #Explorer.Series<
        boolean[5]
        [false, false, true, false, true]
      >
  """
  @doc type: :element_wise
  @spec peaks(series :: Series.t(), max_or_min :: :max | :min) :: Series.t()
  def peaks(series, max_or_min \\ :max)

  def peaks(%Series{dtype: dtype} = series, max_or_min)
      when numeric_or_date_dtype?(dtype),
      do: Shared.apply_impl(series, :peaks, [max_or_min])

  def peaks(%Series{dtype: dtype}, _),
    do: dtype_error("peaks/2", dtype, [:integer, :float, :date, :datetime])

  # Arithmetic

  @doc """
  Adds right to left, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([4, 5, 6])
      iex> Explorer.Series.add(s1, s2)
      #Explorer.Series<
        integer[3]
        [5, 7, 9]
      >

  You can also use scalar values on both sides:

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.add(s1, 2)
      #Explorer.Series<
        integer[3]
        [3, 4, 5]
      >

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.add(2, s1)
      #Explorer.Series<
        integer[3]
        [3, 4, 5]
      >
  """
  @doc type: :element_wise
  @spec add(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def add(left, right), do: basic_numeric_operation(:add, left, right)

  @doc """
  Subtracts right from left, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([4, 5, 6])
      iex> Explorer.Series.subtract(s1, s2)
      #Explorer.Series<
        integer[3]
        [-3, -3, -3]
      >

  You can also use scalar values on both sides:

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.subtract(s1, 2)
      #Explorer.Series<
        integer[3]
        [-1, 0, 1]
      >

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.subtract(2, s1)
      #Explorer.Series<
        integer[3]
        [1, 0, -1]
      >
  """
  @doc type: :element_wise
  @spec subtract(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def subtract(left, right), do: basic_numeric_operation(:subtract, left, right)

  @doc """
  Multiplies left and right, element-wise.

  When mixing floats and integers, the resulting series will have dtype `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s1 = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> s2 = 11..20 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.multiply(s1, s2)
      #Explorer.Series<
        integer[10]
        [11, 24, 39, 56, 75, 96, 119, 144, 171, 200]
      >

      iex> s1 = 1..5 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.multiply(s1, 2)
      #Explorer.Series<
        integer[5]
        [2, 4, 6, 8, 10]
      >
  """
  @doc type: :element_wise
  @spec multiply(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def multiply(left, right), do: basic_numeric_operation(:multiply, left, right)

  @doc """
  Divides left by right, element-wise.

  The resulting series will have the dtype as `:float`.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s1 = [10, 10, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 2] |> Explorer.Series.from_list()
      iex> Explorer.Series.divide(s1, s2)
      #Explorer.Series<
        float[3]
        [5.0, 5.0, 5.0]
      >

      iex> s1 = [10, 10, 10] |> Explorer.Series.from_list()
      iex> Explorer.Series.divide(s1, 2)
      #Explorer.Series<
        float[3]
        [5.0, 5.0, 5.0]
      >

      iex> s1 = [10, 52 ,10] |> Explorer.Series.from_list()
      iex> Explorer.Series.divide(s1, 2.5)
      #Explorer.Series<
        float[3]
        [4.0, 20.8, 4.0]
      >

      iex> s1 = [10, 10, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 0, 2] |> Explorer.Series.from_list()
      iex> Explorer.Series.divide(s1, s2)
      #Explorer.Series<
        float[3]
        [5.0, infinity, 5.0]
      >
  """
  @doc type: :element_wise
  @spec divide(left :: Series.t() | number(), right :: Series.t() | number()) :: Series.t()
  def divide(%Series{} = left, right) do
    left =
      if K.and(
           left.dtype == :integer,
           K.or(is_integer(right), match?(%Series{dtype: :integer}, right))
         ) do
        cast(left, :float)
      else
        left
      end

    basic_numeric_operation(:divide, left, right)
  end

  def divide(left, %Series{} = right) when is_number(left) do
    left =
      if K.and(
           is_integer(left),
           right.dtype == :integer
         ) do
        left / 1.0
      else
        left
      end

    basic_numeric_operation(:divide, left, right)
  end

  @doc """
  Element-wise integer division.

  ## Supported dtype

    * `:integer`

  Returns `nil` if there is a zero in the right-hand side.

  ## Examples

      iex> s1 = [10, 11, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 2] |> Explorer.Series.from_list()
      iex> Explorer.Series.quotient(s1, s2)
      #Explorer.Series<
        integer[3]
        [5, 5, 5]
      >

      iex> s1 = [10, 11, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 0] |> Explorer.Series.from_list()
      iex> Explorer.Series.quotient(s1, s2)
      #Explorer.Series<
        integer[3]
        [5, 5, nil]
      >

      iex> s1 = [10, 12, 15] |> Explorer.Series.from_list()
      iex> Explorer.Series.quotient(s1, 3)
      #Explorer.Series<
        integer[3]
        [3, 4, 5]
      >

  """
  @doc type: :element_wise
  @spec quotient(left :: Series.t(), right :: Series.t() | integer()) :: Series.t()
  def quotient(%Series{dtype: :integer} = left, %Series{dtype: :integer} = right),
    do: Shared.apply_binary_op_impl(:quotient, left, right)

  def quotient(%Series{dtype: :integer} = left, right) when is_integer(right),
    do: Shared.apply_binary_op_impl(:quotient, left, right)

  def quotient(left, %Series{dtype: :integer} = right) when is_integer(left),
    do: Shared.apply_binary_op_impl(:quotient, left, right)

  @doc """
  Computes the remainder of an element-wise integer division.

  ## Supported dtype

    * `:integer`

  Returns `nil` if there is a zero in the right-hand side.

  ## Examples

      iex> s1 = [10, 11, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 2] |> Explorer.Series.from_list()
      iex> Explorer.Series.remainder(s1, s2)
      #Explorer.Series<
        integer[3]
        [0, 1, 0]
      >

      iex> s1 = [10, 11, 10] |> Explorer.Series.from_list()
      iex> s2 = [2, 2, 0] |> Explorer.Series.from_list()
      iex> Explorer.Series.remainder(s1, s2)
      #Explorer.Series<
        integer[3]
        [0, 1, nil]
      >

      iex> s1 = [10, 11, 9] |> Explorer.Series.from_list()
      iex> Explorer.Series.remainder(s1, 3)
      #Explorer.Series<
        integer[3]
        [1, 2, 0]
      >

  """
  @doc type: :element_wise
  @spec remainder(left :: Series.t(), right :: Series.t() | integer()) :: Series.t()
  def remainder(%Series{dtype: :integer} = left, %Series{dtype: :integer} = right),
    do: Shared.apply_binary_op_impl(:remainder, left, right)

  def remainder(%Series{dtype: :integer} = left, right) when is_integer(right),
    do: Shared.apply_binary_op_impl(:remainder, left, right)

  def remainder(left, %Series{dtype: :integer} = right) when is_integer(left),
    do: Shared.apply_binary_op_impl(:remainder, left, right)

  defp basic_numeric_operation(
         operation,
         %Series{dtype: left_dtype} = left,
         %Series{dtype: right_dtype} = right
       )
       when K.and(numeric_dtype?(left_dtype), numeric_dtype?(right_dtype)),
       do: Shared.apply_binary_op_impl(operation, left, right)

  defp basic_numeric_operation(operation, %Series{dtype: left_dtype}, %Series{dtype: right_dtype}),
    do: dtype_mismatch_error("#{operation}/2", left_dtype, right_dtype)

  defp basic_numeric_operation(operation, %Series{dtype: dtype} = left, right)
       when K.and(numeric_dtype?(dtype), is_number(right)),
       do: Shared.apply_binary_op_impl(operation, left, right)

  defp basic_numeric_operation(operation, left, %Series{dtype: dtype} = right)
       when K.and(numeric_dtype?(dtype), is_number(left)),
       do: Shared.apply_binary_op_impl(operation, left, right)

  defp basic_numeric_operation(operation, _, %Series{dtype: dtype}),
    do: dtype_error("#{operation}/2", dtype, [:integer, :float])

  defp basic_numeric_operation(operation, %Series{dtype: dtype}, _),
    do: dtype_error("#{operation}/2", dtype, [:integer, :float])

  @doc """
  Raises a numeric series to the power of the exponent.

  ## Supported dtypes

    * `:integer`
    * `:float`

  ## Examples

      iex> s = [8, 16, 32] |> Explorer.Series.from_list()
      iex> Explorer.Series.pow(s, 2.0)
      #Explorer.Series<
        float[3]
        [64.0, 256.0, 1024.0]
      >

      iex> s = [2, 4, 6] |> Explorer.Series.from_list()
      iex> Explorer.Series.pow(s, 3)
      #Explorer.Series<
        integer[3]
        [8, 64, 216]
      >

      iex> s = [2, 4, 6] |> Explorer.Series.from_list()
      iex> Explorer.Series.pow(s, -3.0)
      #Explorer.Series<
        float[3]
        [0.125, 0.015625, 0.004629629629629629]
      >

      iex> s = [1.0, 2.0, 3.0] |> Explorer.Series.from_list()
      iex> s |> Explorer.Series.pow(3.0)
      #Explorer.Series<
        float[3]
        [1.0, 8.0, 27.0]
      >

      iex> s = [2.0, 4.0, 6.0] |> Explorer.Series.from_list()
      iex> s |> Explorer.Series.pow(2)
      #Explorer.Series<
        float[3]
        [4.0, 16.0, 36.0]
      >
  """
  @doc type: :element_wise
  @spec pow(series :: Series.t(), exponent :: number()) :: Series.t()
  def pow(%Series{dtype: dtype} = series, exponent) when numeric_dtype?(dtype),
    do: Shared.apply_impl(series, :pow, [exponent])

  def pow(%Series{dtype: dtype}, _), do: dtype_error("pow/2", dtype, [:integer, :float])

  # Comparisons

  @doc """
  Returns boolean mask of `left == right`, element-wise.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.equal(s1, s2)
      #Explorer.Series<
        boolean[3]
        [true, true, false]
      >

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.equal(s, 1)
      #Explorer.Series<
        boolean[3]
        [true, false, false]
      >

      iex> s = Explorer.Series.from_list([true, true, false])
      iex> Explorer.Series.equal(s, true)
      #Explorer.Series<
        boolean[3]
        [true, true, false]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.equal(s, "a")
      #Explorer.Series<
        boolean[3]
        [true, false, false]
      >

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.equal(s, ~D[1999-12-31])
      #Explorer.Series<
        boolean[2]
        [false, true]
      >

      iex> s = Explorer.Series.from_list([~N[2022-01-01 00:00:00], ~N[2022-01-01 23:00:00]])
      iex> Explorer.Series.equal(s, ~N[2022-01-01 00:00:00])
      #Explorer.Series<
        boolean[2]
        [true, false]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.equal(s, false)
      ** (ArgumentError) cannot invoke Explorer.Series.equal/2 with mismatched dtypes: string and false.
  """
  @doc type: :element_wise
  @spec equal(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t()
        ) :: Series.t()
  def equal(left, right) do
    if K.or(valid_for_bool_mask_operation?(left, right), sides_comparable?(left, right)) do
      Shared.apply_binary_op_impl(:eq, left, right)
    else
      dtype_mismatch_error("equal/2", dtype_from_sides(left, right), inspect(right))
    end
  end

  @doc """
  Returns boolean mask of `left != right`, element-wise.

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.not_equal(s1, s2)
      #Explorer.Series<
        boolean[3]
        [false, false, true]
      >

      iex> s = Explorer.Series.from_list([1, 2, 3])
      iex> Explorer.Series.not_equal(s, 1)
      #Explorer.Series<
        boolean[3]
        [false, true, true]
      >

      iex> s = Explorer.Series.from_list([true, true, false])
      iex> Explorer.Series.not_equal(s, true)
      #Explorer.Series<
        boolean[3]
        [false, false, true]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.not_equal(s, "a")
      #Explorer.Series<
        boolean[3]
        [false, true, true]
      >

      iex> s = Explorer.Series.from_list([~D[2021-01-01], ~D[1999-12-31]])
      iex> Explorer.Series.not_equal(s, ~D[1999-12-31])
      #Explorer.Series<
        boolean[2]
        [true, false]
      >

      iex> s = Explorer.Series.from_list([~N[2022-01-01 00:00:00], ~N[2022-01-01 23:00:00]])
      iex> Explorer.Series.not_equal(s, ~N[2022-01-01 00:00:00])
      #Explorer.Series<
        boolean[2]
        [false, true]
      >

      iex> s = Explorer.Series.from_list(["a", "b", "c"])
      iex> Explorer.Series.not_equal(s, false)
      ** (ArgumentError) cannot invoke Explorer.Series.not_equal/2 with mismatched dtypes: string and false.
  """
  @doc type: :element_wise
  @spec not_equal(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t() | boolean() | String.t()
        ) :: Series.t()
  def not_equal(left, right) do
    if K.or(valid_for_bool_mask_operation?(left, right), sides_comparable?(left, right)) do
      Shared.apply_binary_op_impl(:neq, left, right)
    else
      dtype_mismatch_error("not_equal/2", dtype_from_sides(left, right), inspect(right))
    end
  end

  defp sides_comparable?(%Series{dtype: :string}, right) when is_binary(right), do: true
  defp sides_comparable?(%Series{dtype: :boolean}, right) when is_boolean(right), do: true
  defp sides_comparable?(_, _), do: false

  @doc """
  Returns boolean mask of `left > right`, element-wise.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.greater(s1, s2)
      #Explorer.Series<
        boolean[3]
        [false, false, false]
      >
  """
  @doc type: :element_wise
  @spec greater(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def greater(left, right) do
    if valid_for_bool_mask_operation?(left, right) do
      Shared.apply_binary_op_impl(:gt, left, right)
    else
      dtype_error("greater/2", dtype_from_sides(left, right), [:integer, :float, :date, :datetime])
    end
  end

  @doc """
  Returns boolean mask of `left >= right`, element-wise.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.greater_equal(s1, s2)
      #Explorer.Series<
        boolean[3]
        [true, true, false]
      >
  """
  @doc type: :element_wise
  @spec greater_equal(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def greater_equal(left, right) do
    if valid_for_bool_mask_operation?(left, right) do
      Shared.apply_binary_op_impl(:gt_eq, left, right)
    else
      dtype_error("greater_equal/2", dtype_from_sides(left, right), [
        :integer,
        :float,
        :date,
        :datetime
      ])
    end
  end

  @doc """
  Returns boolean mask of `left < right`, element-wise.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.less(s1, s2)
      #Explorer.Series<
        boolean[3]
        [false, false, true]
      >
  """
  @doc type: :element_wise
  @spec less(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def less(left, right) do
    if valid_for_bool_mask_operation?(left, right) do
      Shared.apply_binary_op_impl(:lt, left, right)
    else
      dtype_error("less/2", dtype_from_sides(left, right), [:integer, :float, :date, :datetime])
    end
  end

  @doc """
  Returns boolean mask of `left <= right`, element-wise.

  ## Supported dtypes

    * `:integer`
    * `:float`
    * `:date`
    * `:datetime`

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> s2 = Explorer.Series.from_list([1, 2, 4])
      iex> Explorer.Series.less_equal(s1, s2)
      #Explorer.Series<
        boolean[3]
        [true, true, true]
      >
  """
  @doc type: :element_wise
  @spec less_equal(
          left :: Series.t() | number() | Date.t() | NaiveDateTime.t(),
          right :: Series.t() | number() | Date.t() | NaiveDateTime.t()
        ) :: Series.t()
  def less_equal(left, right) do
    if valid_for_bool_mask_operation?(left, right) do
      Shared.apply_binary_op_impl(:lt_eq, left, right)
    else
      dtype_error("less_equal/2", dtype_from_sides(left, right), [
        :integer,
        :float,
        :date,
        :datetime
      ])
    end
  end

  defp valid_for_bool_mask_operation?(%Series{dtype: dtype}, %Series{dtype: dtype}),
    do: true

  defp valid_for_bool_mask_operation?(%Series{dtype: left_dtype}, %Series{dtype: right_dtype})
       when K.and(numeric_dtype?(left_dtype), numeric_dtype?(right_dtype)),
       do: true

  defp valid_for_bool_mask_operation?(%Series{dtype: dtype}, right)
       when K.and(numeric_dtype?(dtype), is_number(right)),
       do: true

  defp valid_for_bool_mask_operation?(%Series{dtype: :date}, %Date{}), do: true

  defp valid_for_bool_mask_operation?(%Series{dtype: :datetime}, %NaiveDateTime{}), do: true

  defp valid_for_bool_mask_operation?(left, %Series{dtype: dtype})
       when K.and(numeric_dtype?(dtype), is_number(left)),
       do: true

  defp valid_for_bool_mask_operation?(%Date{}, %Series{dtype: :date}), do: true

  defp valid_for_bool_mask_operation?(%NaiveDateTime{}, %Series{dtype: :datetime}), do: true

  defp valid_for_bool_mask_operation?(_, _), do: false

  defp dtype_from_sides(%Series{} = left, _right), do: left.dtype
  defp dtype_from_sides(_left, %Series{} = right), do: right.dtype

  defp dtype_from_sides(left, right),
    do:
      raise(
        ArgumentError,
        "expecting series for one of the sides, but got: " <>
          "#{inspect(left)} (lhs) and #{inspect(right)} (rhs)"
      )

  @doc """
  Returns a boolean mask of `left and right`, element-wise

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> mask1 = Explorer.Series.greater(s1, 1)
      iex> mask2 = Explorer.Series.less(s1, 3)
      iex> Explorer.Series.and(mask1, mask2)
      #Explorer.Series<
        boolean[3]
        [false, true, false]
      >

  """
  @doc type: :element_wise
  def (%Series{} = left) and (%Series{} = right),
    do: Shared.apply_impl(left, :binary_and, [right])

  @doc """
  Returns a boolean mask of `left or right`, element-wise

  ## Examples

      iex> s1 = Explorer.Series.from_list([1, 2, 3])
      iex> mask1 = Explorer.Series.less(s1, 2)
      iex> mask2 = Explorer.Series.greater(s1, 2)
      iex> Explorer.Series.or(mask1, mask2)
      #Explorer.Series<
        boolean[3]
        [true, false, true]
      >

  """
  @doc type: :element_wise
  def (%Series{} = left) or (%Series{} = right),
    do: Shared.apply_impl(left, :binary_or, [right])

  @doc """
  Checks equality between two entire series.

  ## Examples

      iex> s1 = Explorer.Series.from_list(["a", "b"])
      iex> s2 = Explorer.Series.from_list(["a", "b"])
      iex> Explorer.Series.all_equal(s1, s2)
      true

      iex> s1 = Explorer.Series.from_list(["a", "b"])
      iex> s2 = Explorer.Series.from_list(["a", "c"])
      iex> Explorer.Series.all_equal(s1, s2)
      false

      iex> s1 = Explorer.Series.from_list(["a", "b"])
      iex> s2 = Explorer.Series.from_list([1, 2])
      iex> Explorer.Series.all_equal(s1, s2)
      false
  """
  @doc type: :element_wise
  def all_equal(%Series{dtype: dtype} = left, %Series{dtype: dtype} = right),
    do: Shared.apply_impl(left, :all_equal, [right])

  def all_equal(%Series{dtype: left_dtype}, %Series{dtype: right_dtype})
      when left_dtype !=
             right_dtype,
      do: false

  # Sort

  @doc """
  Sorts the series.

  ## Examples

      iex> s = Explorer.Series.from_list([9, 3, 7, 1])
      iex> s |> Explorer.Series.sort()
      #Explorer.Series<
        integer[4]
        [1, 3, 7, 9]
      >

  """
  @doc type: :transformation
  def sort(series, reverse \\ false), do: Shared.apply_impl(series, :sort, [reverse])

  @doc """
  Returns the indices that would sort the series.
  """
  @doc type: :transformation
  def argsort(series, reverse \\ false), do: Shared.apply_impl(series, :argsort, [reverse])

  @doc """
  Reverses the series order.

  ## Example

      iex> s = [1, 2, 3] |> Explorer.Series.from_list()
      iex> Explorer.Series.reverse(s)
      #Explorer.Series<
        integer[3]
        [3, 2, 1]
      >
  """
  @doc type: :transformation
  def reverse(series), do: Shared.apply_impl(series, :reverse)

  # Distinct

  @doc """
  Returns the unique values of the series.

  ## Examples

      iex> s = [1, 1, 2, 2, 3, 3] |> Explorer.Series.from_list()
      iex> s |> Explorer.Series.distinct()
      #Explorer.Series<
        integer[3]
        [1, 2, 3]
      >
  """
  @doc type: :transformation
  def distinct(series), do: Shared.apply_impl(series, :distinct)

  @doc """
  Returns the unique values of the series, but does not maintain order.

  Faster than `distinct/1`.

  ## Examples

      iex> s = [1, 1, 2, 2, 3, 3] |> Explorer.Series.from_list()
      iex> s |> Explorer.Series.unordered_distinct()
  """
  @doc type: :transformation
  def unordered_distinct(series), do: Shared.apply_impl(series, :unordered_distinct)

  @doc """
  Returns the number of unique values in the series.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "b", "a", "b"])
      iex> Explorer.Series.n_distinct(s)
      2
  """
  @doc type: :aggregation
  def n_distinct(series), do: Shared.apply_impl(series, :n_distinct)

  @doc """
  Creates a new dataframe with unique values and the count of each.

  In the context of lazy series - using `DataFrame.*_with/2` functions -,
  `count/1` is going to count the elements inside the same group.
  If no group is in use, then count is going to return the length of
  the series.

  ## Examples

      iex> s = Explorer.Series.from_list(["a", "a", "b", "c", "c", "c"])
      iex> Explorer.Series.count(s)
      #Explorer.DataFrame<
        Polars[3 x 2]
        values string ["c", "a", "b"]
        counts integer [3, 2, 1]
      >
  """
  @doc type: :aggregation
  def count(series), do: Shared.apply_impl(series, :count)

  # Window

  @doc """
  Calculate the rolling sum, given a window size and optional list of weights.

  ## Options

    * `:weights` - An optional list of weights with the same length as the window
      that will be multiplied elementwise with the values in the window. Defaults to `nil`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. If `nil`, it will be set equal to window size. Defaults to `1`.

    * `:center` - Set the labels at the center of the window. Defaults to `false`.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_sum(s, 4)
      #Explorer.Series<
        integer[10]
        [1, 3, 6, 10, 14, 18, 22, 26, 30, 34]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_sum(s, 2, weights: [1.0, 2.0])
      #Explorer.Series<
        float[10]
        [1.0, 5.0, 8.0, 11.0, 14.0, 17.0, 20.0, 23.0, 26.0, 29.0]
      >
  """
  @doc type: :window
  def window_sum(series, window_size, opts \\ []),
    do: Shared.apply_impl(series, :window_sum, [window_size, window_opts_with_defaults(opts)])

  @doc """
  Calculate the rolling mean, given a window size and optional list of weights.

  ## Options

    * `:weights` - An optional list of weights with the same length as the window
      that will be multiplied elementwise with the values in the window. Defaults to `nil`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. If `nil`, it will be set equal to window size. Defaults to `1`.

    * `:center` - Set the labels at the center of the window. Defaults to `false`.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_mean(s, 4)
      #Explorer.Series<
        float[10]
        [1.0, 1.5, 2.0, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_mean(s, 2, weights: [1.0, 2.0])
      #Explorer.Series<
        float[10]
        [1.0, 2.5, 4.0, 5.5, 7.0, 8.5, 10.0, 11.5, 13.0, 14.5]
      >
  """
  @doc type: :window
  def window_mean(series, window_size, opts \\ []),
    do: Shared.apply_impl(series, :window_mean, [window_size, window_opts_with_defaults(opts)])

  @doc """
  Calculate the rolling min, given a window size and optional list of weights.

  ## Options

    * `:weights` - An optional list of weights with the same length as the window
      that will be multiplied elementwise with the values in the window. Defaults to `nil`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. If `nil`, it will be set equal to window size. Defaults to `1`.

    * `:center` - Set the labels at the center of the window. Defaults to `false`.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_min(s, 4)
      #Explorer.Series<
        integer[10]
        [1, 1, 1, 1, 2, 3, 4, 5, 6, 7]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_min(s, 2, weights: [1.0, 2.0])
      #Explorer.Series<
        float[10]
        [1.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]
      >
  """
  @doc type: :window
  def window_min(series, window_size, opts \\ []),
    do: Shared.apply_impl(series, :window_min, [window_size, window_opts_with_defaults(opts)])

  @doc """
  Calculate the rolling max, given a window size and optional list of weights.

  ## Options

    * `:weights` - An optional list of weights with the same length as the window
      that will be multiplied elementwise with the values in the window. Defaults to `nil`.

    * `:min_periods` - The number of values in the window that should be non-nil
      before computing a result. If `nil`, it will be set equal to window size. Defaults to `1`.

    * `:center` - Set the labels at the center of the window. Defaults to `false`.

  ## Examples

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_max(s, 4)
      #Explorer.Series<
        integer[10]
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      >

      iex> s = 1..10 |> Enum.to_list() |> Explorer.Series.from_list()
      iex> Explorer.Series.window_max(s, 2, weights: [1.0, 2.0])
      #Explorer.Series<
        float[10]
        [1.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0]
      >
  """
  @doc type: :window
  def window_max(series, window_size, opts \\ []),
    do: Shared.apply_impl(series, :window_max, [window_size, window_opts_with_defaults(opts)])

  defp window_opts_with_defaults(opts) do
    defaults = [weights: nil, min_periods: 1, center: false]

    Keyword.merge(defaults, opts, fn _key, _left, right -> right end)
  end

  # Missing values

  @doc """
  Fill missing values with the given strategy. If a scalar value is provided instead of a strategy
  atom, `nil` will be replaced with that value. It must be of the same `dtype` as the series.

  ## Strategies

    * `:forward` - replace nil with the previous value
    * `:backward` - replace nil with the next value
    * `:max` - replace nil with the series maximum
    * `:min` - replace nil with the series minimum
    * `:mean` - replace nil with the series mean

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :forward)
      #Explorer.Series<
        integer[4]
        [1, 2, 2, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :backward)
      #Explorer.Series<
        integer[4]
        [1, 2, 4, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :max)
      #Explorer.Series<
        integer[4]
        [1, 2, 4, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :min)
      #Explorer.Series<
        integer[4]
        [1, 2, 1, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, :mean)
      #Explorer.Series<
        integer[4]
        [1, 2, 2, 4]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, 3)
      #Explorer.Series<
        integer[4]
        [1, 2, 3, 4]
      >

      iex> s = Explorer.Series.from_list([1.0, 2.0, nil, 4.0])
      iex> Explorer.Series.fill_missing(s, 3.0)
      #Explorer.Series<
        float[4]
        [1.0, 2.0, 3.0, 4.0]
      >

      iex> s = Explorer.Series.from_list(["a", "b", nil, "d"])
      iex> Explorer.Series.fill_missing(s, "c")
      #Explorer.Series<
        string[4]
        ["a", "b", "c", "d"]
      >

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.fill_missing(s, "foo")
      ** (ArgumentError) cannot invoke Explorer.Series.fill_missing/2 with mismatched dtypes: integer and "foo".
  """
  @doc type: :window
  @spec fill_missing(
          Series.t(),
          :forward | :backward | :max | :min | :mean | Explorer.Backend.Series.valid_types()
        ) :: Series.t()
  def fill_missing(%Series{} = series, strategy)
      when strategy in [:forward, :backward, :min, :max, :mean],
      do: Shared.apply_impl(series, :fill_missing, [strategy])

  def fill_missing(%Series{} = series, value) do
    if K.or(
         valid_for_bool_mask_operation?(series, value),
         K.and(is_binary(value), series.dtype == :string)
       ) do
      Shared.apply_impl(series, :fill_missing, [value])
    else
      dtype_mismatch_error("fill_missing/2", series.dtype, inspect(value))
    end
  end

  @doc """
  Returns a mask of nil values.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.is_nil(s)
      #Explorer.Series<
        boolean[4]
        [false, false, true, false]
      >
  """
  @doc type: :element_wise
  @spec is_nil(Series.t()) :: Series.t()
  def is_nil(series), do: Shared.apply_impl(series, :is_nil)

  @doc """
  Returns a mask of not nil values.

  ## Examples

      iex> s = Explorer.Series.from_list([1, 2, nil, 4])
      iex> Explorer.Series.is_not_nil(s)
      #Explorer.Series<
        boolean[4]
        [true, true, false, true]
      >
  """
  @doc type: :element_wise
  @spec is_not_nil(Series.t()) :: Series.t()
  def is_not_nil(series), do: Shared.apply_impl(series, :is_not_nil)

  # Escape hatch

  @doc """
  Returns an `Explorer.Series` where each element is the result of invoking `fun` on each
  corresponding element of `series`.

  This is an expensive operation meant to enable the use of arbitrary Elixir functions against
  any backend. The implementation will vary by backend but in most (all?) cases will require
  converting to an `Elixir.List`, applying `Enum.map/2`, and then converting back to an
  `Explorer.Series`.

  ## Examples

      iex> s = Explorer.Series.from_list(["this ", " is", "great   "])
      iex> Explorer.Series.transform(s, &String.trim/1)
      #Explorer.Series<
        string[3]
        ["this", "is", "great"]
      >

      iex> s = Explorer.Series.from_list(["this", "is", "great"])
      iex> Explorer.Series.transform(s, &String.length/1)
      #Explorer.Series<
        integer[3]
        [4, 2, 5]
      >
  """
  @doc type: :transformation
  def transform(series, fun) do
    case Shared.apply_impl(series, :transform, [fun]) do
      %Series{} = series -> series
      list when is_list(list) -> from_list(list)
    end
  end

  # Helpers

  defp backend_from_options!(opts) do
    backend = Explorer.Shared.backend_from_options!(opts) || Explorer.Backend.get()
    :"#{backend}.Series"
  end

  defp dtype_error(function, dtype, valid_dtypes),
    do:
      raise(
        ArgumentError,
        "Explorer.Series.#{function} not implemented for dtype #{inspect(dtype)}. Valid " <>
          "dtypes are #{inspect(valid_dtypes)}."
      )

  defp dtype_mismatch_error(function, left_dtype, right_dtype),
    do:
      raise(
        ArgumentError,
        "cannot invoke Explorer.Series.#{function} with mismatched dtypes: #{left_dtype} and " <>
          "#{right_dtype}."
      )

  defp check_dtypes_for_coalesce!(%Series{} = s1, %Series{} = s2) do
    case {s1.dtype, s2.dtype} do
      {dtype, dtype} -> :ok
      {:integer, :float} -> :ok
      {:float, :integer} -> :ok
      {left, right} -> dtype_mismatch_error("coalesce/2", left, right)
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(df, opts) do
      force_unfit(
        concat([
          color("#Explorer.Series<", :map, opts),
          nest(
            concat([line(), Shared.apply_impl(df, :inspect, [opts])]),
            2
          ),
          line(),
          color(">", :map, opts)
        ])
      )
    end
  end
end
