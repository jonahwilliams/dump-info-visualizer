// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dump_viz.view_version;

import 'dart:html';

import 'history_state.dart';
import 'info_helper.dart';
import 'logical_row.dart';
import 'tree_table.dart';
import 'util.dart';

class ViewVersion {
  final InfoHelper model;
  final TreeTable treeTable;

  final Function switchToHierTab;
  final Function switchToDepsTab;

  ViewVersion(
      this.model, this.treeTable, this.switchToHierTab, this.switchToDepsTab);

  void display() {
    treeTable.columnInfo(
        // Names
        ['Kind', 'Name', 'Bytes', 'Bytes R', '%', 'Type'],
        // Help Info
        [
      '',
      'The given name of the element',
      'The direct size attributed to the element',
      'The sum of the sizes of all the elements that can '
          'only be reached from this element',
      'The percentage of the direct size compared to the '
          'program size',
      'The given type of the element'
    ],
        // Sizes
        ["200px", null, "100px", "100px", "70px", null]);

    _setupProgramwideInfo();

    int programSize = model.size;

    // A helper function for lazilly constructing the tree
    LogicalRow buildTree(String id, bool isTop, HtmlElement tbody, int level) {
      Map<String, dynamic> node = model.elementById(id);
      if (node['size'] == null) {
        node['size'] = computeSize(node, model.elementById);
      }
      node['size_percent'] =
          (100 * node['size'] / programSize).toStringAsFixed(2) + '%';

      var row = new LogicalRow(node, _renderRow1, tbody, level);
      _addMetadata(node, row, tbody, level + 1, model.elementById);

      if (isTop) {
        treeTable.addTopLevel(row);
      }

      if (node['children'] != null) {
        for (var childId in node['children']) {
          // Thunk!  Lazy tree creation happens in this closure.
          row.addChild(() => buildTree(childId, false, tbody, level + 1));
        }
      }
      return row;
    }

    // Start building the tree from the libraries because
    // libraries are always the top level.
    for (String libraryId in model.allOfType('library').map((a) => a['id'])) {
      buildTree('$libraryId', true, treeTable.tbody, 0).show();
    }
  }

  void mapToTable(TableElement table, Map<String, dynamic> map) {
    map.forEach((k, v) {
      TableRowElement row = table.addRow();
      row.addCell()..text = k;
      if (v is String) {
        row.addCell()..text = v;
      } else if (v is Element) {
        row.addCell()..children.add(v);
      } else {
        throw new ArgumentError("Unexpected value in map: $v");
      }
    });
  }

  void _setupProgramwideInfo() {
    TableElement programInfoTable = querySelector('#prog-info') as TableElement;
    programInfoTable.children.clear();
    mapToTable(programInfoTable, {
      'Program Size': model.size.toString() + ' bytes',
      'Compile Time': model.compilationMoment,
      'Compile Duration': model.compilationDuration,
      'noSuchMethod Enabled': new SpanElement()
        ..text = model.noSuchMethodEnabled.toString()
        ..style.background = model.noSuchMethodEnabled ? "red" : "white",
      // TODO(tyoverby): add support for loading files generated by
      // TRACE_CALLS and compare them to the functions that are produced
      // by dart2js.
      'Extract Function Names': new ButtonElement()
        ..text = 'extract'
        ..onClick.listen((_) {
          String text =
              model.allOfType('function').map((a) => "${a['name']}").join(', ');
          text = Uri.encodeComponent('[$text]');
          String encoded = 'data:text/plain;charset=utf-8,$text';

          AnchorElement downloadLink = new AnchorElement(href: encoded);
          downloadLink.text = 'download file';
          downloadLink.setAttribute('download', 'functions.txt');
          downloadLink.click();
        })
    });
  }

  /**
   * A helper method for adding rows that are not elements but instead provide
   * extra information about an element.
   */
  void _addMetadata(Map<String, dynamic> node, LogicalRow row,
      HtmlElement tbody, int level, Function fetch) {

    // A helper method for generating a row-generating function.
    GenerateRowFunction renderSelfWith(Function renderFn,
        {int sortPriority: 0}) {
      void render(TreeTableRow row, LogicalRow lRow) {
        row.data = renderFn();
      }
      return () {
        LogicalRow lrow =
            new LogicalRow(node, render, row.parentElement, level);
        lrow.sortable = false;
        lrow.nonSortablePriority = sortPriority;
        return lrow;
      };
    }

    switch (node['kind']) {
      case 'function':
      case 'closure':
      case 'constructor':
      case 'method':
        // Side Effects
        row.addChild(renderSelfWith(() => [
          cell('side effects'),
          cell(node['sideEffects'], colspan: '5')
        ]));
        // Modifiers
        if (node.containsKey('modifiers')) {
          (node['modifiers'] as Map<String, bool>).forEach((k, v) {
            if (v) {
              row.addChild(renderSelfWith(
                  () => [cell('modifier'), cell(k, colspan: '5')]));
            }
          });
        }
        // Return type
        row.addChild(renderSelfWith(() => [
          cell('return type'),
          _typeCell(node['returnType'], node['inferredReturnType'],
              colspan: '5')
        ]));
        // Parameters
        if (node.containsKey('parameters')) {
          for (Map<String, dynamic> param in node['parameters']) {
            String declaredType = param['declaredType'] == null
                ? "unavailable"
                : param['declaredType'];
            row.addChild(renderSelfWith(() => [
              cell('parameter'),
              cell(param['name']),
              _typeCell(declaredType, param['type'], colspan: '4')
            ]));
          }
        }
        // Code
        if (node['code'] != null && node['code'].length != 0) {
          row.addChild(renderSelfWith(
              () => [cell('code'), cell(node['code'], colspan: '5', pre: true)],
              sortPriority: -1));
        }
        break;
      case 'field':
        // Code
        if (node['code'] != null && node['code'].length != 0) {
          row.addChild(renderSelfWith(
              () => [cell('code'), cell(node['code'], colspan: '5', pre: true)],
              sortPriority: -1));
        }
        // Types
        if (node['inferredType'] != null && node['type'] != null) {
          row.addChild(renderSelfWith(() => [
            cell('type'),
            _typeCell(node['type'], node['inferredType'], colspan: '5')
          ]));
        }
        break;
      case 'class':
      case 'library':
        // Show how much of the size we can't account for.
        row.addChild(renderSelfWith(() => [
          cell('scaffolding'),
          cell('(unaccounted for)'),
          cell(node['size'] - computeSize(node, fetch, force: true),
              align: 'right')
        ]));
        break;
    }
  }

  void _renderRow1(TreeTableRow row, LogicalRow logicalRow) {
    Map<String, dynamic> props = logicalRow.data;
    List<TableCellElement> cells = [cell(props['kind']),];

    switch (props['kind']) {
      case 'function':
      case 'closure':
      case 'constructor':
      case 'method':
      case 'field':
        var span = new SpanElement();
        span.text = props['name'];

        var anchor = new AnchorElement();
        anchor.onClick.listen((_) {
          HistoryState
              .switchTo(new HistoryState('dep', depTarget: props['id']));
        });
        anchor.children
            .add(new ImageElement(src: 'deps_icon.svg')..style.float = 'right');

        cells.addAll([
          new TableCellElement()..children.addAll([span, anchor]),
          cell(props['size'], align: 'right'),
          cell(model.triviallyOwnedSize(props['id']), align: 'right'),
          cell(props['size_percent'], align: 'right'),
          cell(props['type'], pre: true)
        ]);
        break;
      case 'library':
        cells.addAll([
          cell(props['name']),
          cell(props['size'], align: 'right'),
          cell(''),
          cell(props['size_percent'], align: 'right'),
          cell('')
        ]);
        break;
      case 'typedef':
        cells.addAll([
          cell(props['name']),
          cell('0', align: 'right'),
          cell('0', align: 'right'),
          cell('0.00%', align: 'right')
        ]);
        break;
      case 'class':
        cells.addAll([
          cell(props['name']),
          cell(props['size'], align: 'right'),
          cell(''),
          cell(props['size_percent'], align: 'right'),
          cell(props['name'], pre: true)
        ]);
        break;
      default:
        throw new StateError("Unknown element type: ${props['kind']}");
    }
    row.data = cells;
  }

  static _typeCell(String declaredType, String inferredType, {colspan: '1'}) {
    return _verticalCell(new SpanElement()
      ..appendText('inferred: ')
      ..append(_span(inferredType, cssClass: 'preSpan')), new SpanElement()
      ..appendText('declared: ')
      ..append(_span(declaredType, cssClass: 'preSpan')), colspan: colspan);
  }
}

TableCellElement _verticalCell(dynamic upper, dynamic lower,
    {String align: 'left', String colspan: '1'}) {
  DivElement div = new DivElement();
  div.children.addAll([
    upper is SpanElement ? upper : _span(upper),
    new BRElement(),
    lower is SpanElement ? lower : _span(lower)
  ]);
  return cell(div, align: align, colspan: colspan, pre: false);
}

SpanElement _span(dynamic contents, {String cssClass}) {
  SpanElement span = new SpanElement();
  if (cssClass != null) span.classes.add(cssClass);
  if (contents is Node) {
    span.append(contents);
  } else {
    span.appendText('$contents');
  }
  return span;
}
