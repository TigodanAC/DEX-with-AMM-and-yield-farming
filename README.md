# FarmSwap DEX with Yield Farming

## Описание проекта

**FarmSwap** - это децентрализованная биржа (DEX) с автоматическим маркет-мейкером (AMM) и встроенным yield farming.
Пользователи могут:

* добавлять ликвидность в пул TOKEN_A / TOKEN_B,
* получать LP-долю пула,
* зарабатывать награды в REWARD_TOKEN пропорционально своей доле ликвидности,
* выполнять свопы между токенами с комиссией и протокольным сбором.

Контракт реализует:

* AMM по формуле `x * y = k`,
* распределение наград во времени (`rewardRate`),
* протокольные комиссии,
* защиту от reentrancy,
* паузу протокола,
* блокировку повторного получения наград (lock period).

---

## Запуск и деплой в Remix

### 1. Выбор окружения

1. Откройте **Remix IDE**: [https://remix.ethereum.org](https://remix.ethereum.org)
2. Перейдите во вкладку **Deploy & Run Transactions**
3. В поле **Environment** выберите:
   **Remix VM (London)**
4. Убедитесь, что выбран аккаунт с ETH (по умолчанию - первый)

---

### 2. Деплой ERC20 токенов

Контракт `ERC20Mock` используется для TOKEN_A, TOKEN_B и REWARD_TOKEN.

#### Token A

1. Откройте файл `ERC20Mock.sol`
2. Нажмите **Compile ERC20Mock.sol**
3. Во вкладке **Deploy & Run Transactions** выберите
   **ERC20Mock**
4. Параметры конструктора:

   * `name`: `Token A`
   * `symbol`: `TKA`
   * `initialSupply`:
     `1000000000000000000000000` (1 000 000 токенов, 18 decimals)
5. Нажмите **Transact**
6. Скопируйте адрес задеплоенного токена

#### Token B

Повторите шаги выше:

* `name`: `Token B`
* `symbol`: `TKB`

#### Reward Token

Повторите шаги выше:

* `name`: `Reward Token`
* `symbol`: `RWD`

---

### 3. Деплой FarmSwap

1. Откройте файл `FarmSwap.sol`
2. Нажмите **Compile FarmSwap.sol**
3. Во вкладке **Deploy & Run Transactions** выберите
   **FarmSwap**
4. Параметры конструктора:

   * `_tokenA`: адрес Token A
   * `_tokenB`: адрес Token B
   * `_rewardToken`: адрес Reward Token
5. Нажмите **Transact**
6. Скопируйте адрес FarmSwap

Контракт деплоится **в состоянии pause**

---

### 4. Настройка approve

Для корректной работы необходимо выдать разрешения FarmSwap.

#### Для Token A, Token B и Reward Token:

1. Откройте контракт токена в **Deployed Contracts**
2. Вызовите `approve`:

   * `spender`: адрес FarmSwap
   * `amount`:
     `1000000000000000000000000`
3. Нажмите **Transact**

---

### 5. Настройка наград

#### Назначение дистрибьютора наград

(по умолчанию владелец уже является дистрибьютором, шаг можно пропустить)

1. В FarmSwap вызовите `setRewardDistributor`

   * `distributor`: ваш адрес
   * `status`: `true`

#### Финансирование пула наград

1. В FarmSwap вызовите `fundRewards`

   * `amount`:
     `1000000000000000000000` (1000 RWD)

---

### 6. Активация контракта

В FarmSwap вызовите `unpause`. После этого пользовательские функции становятся доступными.

---

## Базовые сценарии

### 1. Добавление ликвидности

```text
addLiquidity(
  amountA = 100000000000000000000, // 100 TKA
  amountB = 100000000000000000000  // 100 TKB
)
```

Проверка:

* `lpBalances(address)` > 0
* `getReserves()` показывает обновлённые резервы

---

### 2. Своп токенов

```text
swap(
  tokenIn = Token A,
  amountIn = 10000000000000000000,  // 10 TKA
  minAmountOut = 9000000000000000000 // минимум 9 TKB
)
```

Проверка:

* Баланс Token B увеличился
* Резервы изменились
* Протокольная комиссия учтена в `protocolFeesA/B`

---

### 3. Проверка и получение наград

1. Подождите некоторое время (накапливается reward)
2. Вызовите:

   ```text
   earned(ваш_адрес)
   ```
3. Вызовите:

   ```text
   claimRewards()
   ```

#### Lock period

* После `claimRewards` **повторное получение наград заблокировано на 1 день**
* Lock хранится в `userLockEndTime`

---

### 4. Удаление ликвидности

```text
removeLiquidity(liquidity)
```

* `liquidity` - значение из `lpBalances`
* Пользователь получает TOKEN_A и TOKEN_B обратно пропорционально доле

---

### 5. Протокольные комиссии

1. После нескольких свопов:

   * `protocolFeesA`
   * `protocolFeesB`
2. Владелец может вызвать:

   ```text
   withdrawProtocolFees()
   ```

---

## Полезные view-функции

* `getReserves()` - текущие резервы пула
* `earned(address)` - накопленные награды
* `totalRewards()` - оставшиеся награды
* `rewardRate()` - скорость распределения наград
* `lpBalances(address)` - LP-доля пользователя

---

## Безопасность и ограничения

В контракте есть:

* `ReentrancyGuard` - защита от reentrancy
* `Pausable` - аварийная остановка
* Ограничение `MAX_REWARD_RATE`
* Проверка slippage при добавлении ликвидности
* Протокольная комиссия со свопов
* Период ожидания между получением наград (1 день)
* Аварийный вывод токенов, не относящихся к пулу