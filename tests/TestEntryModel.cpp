/*
 *  Copyright (C) 2010 Felix Geyer <debfx@fobos.de>
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 2 or (at your option)
 *  version 3 of the License.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "TestEntryModel.h"

#include <QtTest/QSignalSpy>
#include <QtTest/QTest>

#include "modeltest.h"
#include "tests.h"
#include "core/DatabaseIcons.h"
#include "core/Entry.h"
#include "core/Group.h"
#include "crypto/Crypto.h"
#include "gui/EntryModel.h"
#include "gui/EntryAttachmentsModel.h"
#include "gui/EntryAttributesModel.h"
#include "gui/IconModels.h"

void TestEntryModel::initTestCase()
{
    qRegisterMetaType<QModelIndex>("QModelIndex");
    Crypto::init();
}

void TestEntryModel::test()
{
    Group* group1 = new Group();
    Group* group2 = new Group();

    Entry* entry1 = new Entry();
    entry1->setGroup(group1);
    entry1->setTitle("testTitle1");

    Entry* entry2 = new Entry();
    entry2->setGroup(group1);
    entry2->setTitle("testTitle2");

    EntryModel* model = new EntryModel(this);

    ModelTest* modelTest = new ModelTest(model, this);

    model->setGroup(group1);

    QCOMPARE(model->rowCount(), 2);

    QSignalSpy spyDataChanged(model, SIGNAL(dataChanged(const QModelIndex&, const QModelIndex&)));
    entry1->setTitle("changed");
    QCOMPARE(spyDataChanged.count(), 1);

    QModelIndex index1 = model->index(0, 1);
    QModelIndex index2 = model->index(1, 1);

    QCOMPARE(model->data(index1).toString(), entry1->title());
    QCOMPARE(model->data(index2).toString(), entry2->title());

    QSignalSpy spyAboutToAdd(model, SIGNAL(rowsAboutToBeInserted(const QModelIndex&,int,int)));
    QSignalSpy spyAdded(model, SIGNAL(rowsInserted(const QModelIndex&,int,int)));
    QSignalSpy spyAboutToRemove(model, SIGNAL(rowsAboutToBeRemoved(const QModelIndex&,int,int)));
    QSignalSpy spyRemoved(model, SIGNAL(rowsRemoved(const QModelIndex&,int,int)));

    Entry* entry3 = new Entry();
    entry3->setGroup(group1);

    QCOMPARE(spyAboutToAdd.count(), 1);
    QCOMPARE(spyAdded.count(), 1);
    QCOMPARE(spyAboutToRemove.count(), 0);
    QCOMPARE(spyRemoved.count(), 0);

    entry2->setGroup(group2);

    QCOMPARE(spyAboutToAdd.count(), 1);
    QCOMPARE(spyAdded.count(), 1);
    QCOMPARE(spyAboutToRemove.count(), 1);
    QCOMPARE(spyRemoved.count(), 1);

    QSignalSpy spyReset(model, SIGNAL(modelReset()));
    model->setGroup(group2);
    QCOMPARE(spyReset.count(), 1);

    delete group1;
    delete group2;

    delete modelTest;
    delete model;
}

void TestEntryModel::testAttachmentsModel()
{
    EntryAttachments* entryAttachments = new EntryAttachments(this);

    EntryAttachmentsModel* model = new EntryAttachmentsModel(this);
    ModelTest* modelTest = new ModelTest(model, this);

    QCOMPARE(model->rowCount(), 0);
    model->setEntryAttachments(entryAttachments);
    QCOMPARE(model->rowCount(), 0);

    QSignalSpy spyDataChanged(model, SIGNAL(dataChanged(QModelIndex,QModelIndex)));
    QSignalSpy spyAboutToAdd(model, SIGNAL(rowsAboutToBeInserted(QModelIndex,int,int)));
    QSignalSpy spyAdded(model, SIGNAL(rowsInserted(QModelIndex,int,int)));
    QSignalSpy spyAboutToRemove(model, SIGNAL(rowsAboutToBeRemoved(QModelIndex,int,int)));
    QSignalSpy spyRemoved(model, SIGNAL(rowsRemoved(QModelIndex,int,int)));

    entryAttachments->set("first", QByteArray("123"));

    entryAttachments->set("2nd", QByteArray("456"));
    entryAttachments->set("2nd", QByteArray("789"));

    QCOMPARE(model->data(model->index(0, 0)).toString().left(4), QString("2nd "));

    entryAttachments->remove("first");

    QCOMPARE(spyDataChanged.count(), 1);
    QCOMPARE(spyAboutToAdd.count(), 2);
    QCOMPARE(spyAdded.count(), 2);
    QCOMPARE(spyAboutToRemove.count(), 1);
    QCOMPARE(spyRemoved.count(), 1);

    QSignalSpy spyReset(model, SIGNAL(modelReset()));
    entryAttachments->clear();
    model->setEntryAttachments(0);
    QCOMPARE(spyReset.count(), 2);
    QCOMPARE(model->rowCount(), 0);

    delete modelTest;
    delete model;
    delete entryAttachments;
}

void TestEntryModel::testAttributesModel()
{
    EntryAttributes* entryAttributes = new EntryAttributes(this);

    EntryAttributesModel* model = new EntryAttributesModel(this);
    ModelTest* modelTest = new ModelTest(model, this);

    QCOMPARE(model->rowCount(), 0);
    model->setEntryAttributes(entryAttributes);
    QCOMPARE(model->rowCount(), 0);

    QSignalSpy spyDataChanged(model, SIGNAL(dataChanged(QModelIndex,QModelIndex)));
    QSignalSpy spyAboutToAdd(model, SIGNAL(rowsAboutToBeInserted(QModelIndex,int,int)));
    QSignalSpy spyAdded(model, SIGNAL(rowsInserted(QModelIndex,int,int)));
    QSignalSpy spyAboutToRemove(model, SIGNAL(rowsAboutToBeRemoved(QModelIndex,int,int)));
    QSignalSpy spyRemoved(model, SIGNAL(rowsRemoved(QModelIndex,int,int)));

    entryAttributes->set("first", "123");

    entryAttributes->set("2nd", "456");
    entryAttributes->set("2nd", "789");

    QCOMPARE(model->data(model->index(0, 0)).toString(), QString("2nd"));

    entryAttributes->remove("first");

    // make sure these don't generate messages
    entryAttributes->set("Title", "test");
    entryAttributes->set("Notes", "test");

    QCOMPARE(spyDataChanged.count(), 1);
    QCOMPARE(spyAboutToAdd.count(), 2);
    QCOMPARE(spyAdded.count(), 2);
    QCOMPARE(spyAboutToRemove.count(), 1);
    QCOMPARE(spyRemoved.count(), 1);

    QSignalSpy spyReset(model, SIGNAL(modelReset()));
    entryAttributes->clear();
    model->setEntryAttributes(0);
    QCOMPARE(spyReset.count(), 2);
    QCOMPARE(model->rowCount(), 0);

    delete modelTest;
    delete model;
}

void TestEntryModel::testDefaultIconModel()
{
    DefaultIconModel* model = new DefaultIconModel(this);
    ModelTest* modelTest = new ModelTest(model, this);

    QCOMPARE(model->rowCount(), databaseIcons()->iconCount());

    delete modelTest;
    delete model;
}

void TestEntryModel::testCustomIconModel()
{
    CustomIconModel* model = new CustomIconModel(this);
    ModelTest* modelTest = new ModelTest(model, this);

    QCOMPARE(model->rowCount(), 0);

    QHash<Uuid, QImage> icons;
    QList<Uuid> iconsOrder;

    Uuid iconUuid(QByteArray(16, '2'));
    QImage icon;
    icons.insert(iconUuid, icon);
    iconsOrder << iconUuid;

    Uuid iconUuid2(QByteArray(16, '1'));
    QImage icon2;
    icons.insert(iconUuid2, icon2);
    iconsOrder << iconUuid2;

    model->setIcons(icons, iconsOrder);
    QCOMPARE(model->uuidFromIndex(model->index(0, 0)), iconUuid);
    QCOMPARE(model->uuidFromIndex(model->index(1, 0)), iconUuid2);

    delete modelTest;
    delete model;
}

KEEPASSX_QTEST_CORE_MAIN(TestEntryModel)
